//! Independently owned, allocation-free decoding work submitted through the
//! caller's native std.Io executor. The task descriptor's address must remain
//! stable until the future is awaited/cancelled.
const std = @import("std");
const layout_mod = @import("../format/layout.zig");
const pool_mod = @import("../batch/storage.zig");
const completion = @import("completion.zig");
const fault_injection = @import("../testing/fault_injection.zig");
const property_mod = @import("../format/property.zig");
const preflight = @import("../decode/ascii/preflight.zig");

pub const State = enum { prepared, submitted, running, completed, failed, cancelled, reclaimed };
pub const CompletionQueue = std.Io.Queue(completion.Completion);

/// Actual simultaneous decodes, independent of submitted task count.
pub const Activity = struct {
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    pub fn start(self: *Activity) void {
        const n = self.active.fetchAdd(1, .acq_rel) + 1;
        var old = self.peak.load(.monotonic);
        while (old < n) {
            if (self.peak.cmpxchgWeak(old, n, .acq_rel, .monotonic)) |observed| {
                old = observed;
            } else break;
        }
    }
    pub fn finish(self: *Activity) void {
        _ = self.active.fetchSub(1, .acq_rel);
    }
};

pub const DecodeTask = struct {
    sequence: u64,
    element_index: usize,
    first_record: u64,
    byte_offset: u64 = 0,
    record_count: usize,
    input: []const u8,
    layout: *const layout_mod.ElementLayout,
    endian: std.builtin.Endian,
    encoding: enum { binary, binary_variable, ascii } = .binary,
    binary_boundaries: []const usize = &.{},
    binary_totals: []const usize = &.{},
    ascii_boundaries: []const usize = &.{},
    ascii_properties: []const property_mod.Property = &.{},
    ascii_token_limit: usize = 0,
    ascii_item_limit: usize = 0,
    ascii_first_line_number: u64 = 0,
    ascii_failure: preflight.Failure = .{},
    pool: *pool_mod.Pool,
    slot_id: usize,

    /// Captures the column allocations before dispatch. The pool's slot table
    /// can grow while decode is running; the task never accesses that table.
    target: ?pool_mod.Pool.Target = null,
    notification: ?*CompletionQueue = null,
    /// On notification failure, close the queue to wake a blocked collector.
    notification_failure: ?*std.atomic.Value(bool) = null,
    notification_key: completion.Completion = .{ .slot_id = 0, .generation = 0, .sequence = 0 },
    execution_io: ?std.Io = null,
    activity: ?*Activity = null,
    /// Internal deterministic test instrumentation. Never set by normal callers.
    test_hooks: ?*const fault_injection.Hooks = null,

    state: State = .prepared,
    failure: ?anyerror = null,
    failure_info: ?TaskFailure = null,
    future: ?std.Io.Future(anyerror!void) = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub const TaskFailure = struct {
        sequence: u64,
        element_index: usize,
        first_record: u64,
        byte_offset: u64 = 0,
        record_count: usize,
        error_value: anyerror,
        property_index: ?usize = null,
        record_index: usize = 0,
        token_offset: ?usize = null,
    };

    fn notify(self: *DecodeTask) void {
        if (@import("builtin").is_test) {
            if (self.test_hooks) |hooks| {
                if (hooks.before_notify) |callback| callback(hooks.context, self.sequence);
            }
        }
        if (self.notification) |queue| {
            // Completion capacity >= admitted task count. This call cannot
            // block on a full queue while the scheduler is joining tasks.
            var inject_failure = false;
            if (@import("builtin").is_test) {
                if (self.test_hooks) |hooks| {
                    if (hooks.fail_notification) |callback| inject_failure = callback(hooks.context, self.sequence);
                }
            }
            const result: anyerror!void = if (inject_failure)
                error.InjectedNotificationFailure
            else
                queue.putOneUncancelable(self.execution_io.?, self.notification_key);
            result catch {
                // Silently dropping the completion would strand an unordered
                // Parser.next() in getOne() forever. Closing the queue wakes
                // the coordinator, which cancels and joins pending futures.
                if (self.notification_failure) |failed| {
                    if (!failed.swap(true, .acq_rel)) {
                        queue.close(self.execution_io.?);
                    }
                } else {
                    // Every native completion queue must carry a failure
                    // channel. A missing channel is a programming error.
                    @panic("completion notification failed without failure channel");
                }
            };
        }
        if (@import("builtin").is_test) {
            if (self.test_hooks) |hooks| {
                if (hooks.after_notify) |callback| callback(hooks.context, self.sequence);
            }
        }
    }

    fn runConcurrent(self: *DecodeTask) anyerror!void {
        const result = self.execute();
        self.notify();
        return result;
    }

    /// Starts actual CPU concurrency when the chosen Io implementation can
    /// supply it. No user-visible worker/thread configuration is involved.
    pub fn submit(self: *DecodeTask, io: std.Io) error{ConcurrencyUnavailable}!void {
        if (self.state != .prepared) return error.ConcurrencyUnavailable;
        self.execution_io = io;
        self.state = .submitted; // before launch; worker must not race this write
        self.future = io.concurrent(runConcurrent, .{self}) catch {
            self.state = .prepared;
            return error.ConcurrencyUnavailable;
        };
    }

    /// Executes fallback work and publishes the same completion event that a
    /// concurrent task would publish. Must be called at most once per task.
    pub fn runInline(self: *DecodeTask, io: std.Io) anyerror!void {
        self.execution_io = io;
        const result = self.execute();
        self.notify();
        return result;
    }

    pub fn await(self: *DecodeTask, io: std.Io) anyerror!void {
        if (self.future) |*future| {
            const result = future.await(io);
            self.future = null;
            return result;
        }
        switch (self.state) {
            .completed => return,
            .failed => return self.failure orelse error.InvalidTaskState,
            .cancelled => return error.Cancelled,
            else => return error.InvalidTaskState,
        }
    }

    /// Stop requests are atomic and cooperative. Never mutate the running
    /// worker's state from the coordinator before joining its future.
    pub fn cancelFuture(self: *DecodeTask, io: std.Io) anyerror!void {
        self.cancel_requested.store(true, .release);
        if (self.future) |*future| {
            const result = future.cancel(io);
            self.future = null;
            return result;
        }
    }

    pub fn execute(self: *DecodeTask) anyerror!void {
        if (self.state != .prepared and self.state != .submitted) return error.InvalidTaskState;
        if (self.cancel_requested.load(.acquire)) {
            self.state = .cancelled;
            return error.Cancelled;
        }
        self.state = .running;
        if (self.activity) |a| a.start();
        defer if (self.activity) |a| a.finish();
        const injected: ?anyerror = if (@import("builtin").is_test) blk: {
            if (self.test_hooks) |hooks| {
                if (hooks.decode_failure) |callback|
                    break :blk callback(hooks.context, self.sequence);
            }
            break :blk null;
        } else null;
        const result: anyerror!void = if (injected) |err| err else switch (self.encoding) {
            .ascii => pool_mod.Pool.decodePreparedAsciiWithHooks(
                self.target orelse return error.InvalidTaskState,
                self.ascii_properties,
                self.input,
                self.ascii_boundaries,
                self.ascii_token_limit,
                self.ascii_item_limit,
                &self.cancel_requested,
                &self.ascii_failure,
                self.test_hooks,
                self.sequence,
            ),
            .binary_variable => pool_mod.Pool.decodePreparedBinaryVariableWithHooks(
                self.target orelse return error.InvalidTaskState,
                self.layout,
                self.endian,
                self.input,
                self.binary_boundaries,
                self.binary_totals,
                &self.cancel_requested,
                self.test_hooks,
                self.sequence,
            ),
            .binary => if (self.target) |dest|
                pool_mod.Pool.decodePreparedWithHooks(dest, self.layout, self.endian, self.input, self.record_count, &self.cancel_requested, self.test_hooks, self.sequence)
            else
                self.pool.decodeCancelable(self.slot_id, self.layout, self.endian, self.input, self.record_count, &self.cancel_requested),
        };
        result catch |err| {
            self.failure = err;
            self.failure_info = .{
                .sequence = self.sequence,
                .element_index = self.element_index,
                .first_record = self.first_record,
                .byte_offset = self.byte_offset,
                .record_count = self.record_count,
                .error_value = err,
                .property_index = if (self.encoding == .ascii) self.ascii_failure.property_index else null,
                .record_index = if (self.encoding == .ascii) self.ascii_failure.record_index else 0,
                .token_offset = if (self.encoding == .ascii) self.ascii_failure.token_offset else null,
            };
            self.state = if (err == error.Cancelled) .cancelled else .failed;
            return err;
        };
        self.state = .completed;
    }

    pub fn cancel(self: *DecodeTask) error{InvalidTaskState}!void {
        self.cancel_requested.store(true, .release);
        if (self.state == .prepared) self.state = .cancelled;
    }
};
