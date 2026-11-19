//! Bounded execution window for independently owned decode tasks.
//! Callers must not move a Window while futures reference its slots.
const std = @import("std");
const task_mod = @import("task.zig");
const completion = @import("completion.zig");

pub const Window = struct {
    const capacity: usize = 2;
    slots: [capacity]Slot = .{ .{}, .{} },
    completion_backing: [capacity]completion.Completion = undefined,
    queue: task_mod.CompletionQueue = undefined,
    notification_failed: std.atomic.Value(bool) = .init(false),
    queue_initialized: bool = false,
    closed: bool = false,
    next_delivery: u64 = 0,
    delivery_mode: enum { unset, ordered, unordered } = .unset,

    const Slot = struct {
        active: bool = false,
        generation: u64 = 0,
        task: task_mod.DecodeTask = undefined,
    };

    pub fn pending(self: *const Window) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }

    pub fn submit(self: *Window, io: std.Io, task: task_mod.DecodeTask) error{ WindowFull, ConcurrencyUnavailable }!void {
        if (self.closed) return error.WindowFull;
        if (!self.queue_initialized) {
            self.notification_failed = .init(false);
            self.queue = .init(&self.completion_backing);
            self.queue_initialized = true;
        }
        for (&self.slots, 0..) |*slot, i| {
            if (slot.active) continue;
            if (slot.generation == std.math.maxInt(u64)) return error.WindowFull;
            slot.generation += 1;
            slot.task = task;
            slot.task.notification = &self.queue;
            slot.task.notification_failure = &self.notification_failed;
            slot.task.notification_key = .{
                .slot_id = i,
                .generation = slot.generation,
                .sequence = task.sequence,
            };
            slot.active = true;
            slot.task.submit(io) catch {
                _ = slot.task.runInline(io) catch {};
            };
            return;
        }
        return error.WindowFull;
    }

    fn popSlot(self: *Window, io: std.Io, index: usize) anyerror!task_mod.DecodeTask {
        const slot = &self.slots[index];
        std.debug.assert(slot.active);
        const result = slot.task.await(io);
        slot.active = false;
        result catch |err| {
            // The failed task never became a consumer lease.
            slot.task.pool.cancel(slot.task.slot_id);
            return err;
        };
        if (slot.task.state != .completed) {
            slot.task.pool.cancel(slot.task.slot_id);
            return error.TaskDidNotComplete;
        }
        return slot.task;
    }

    pub fn popNext(self: *Window, io: std.Io) anyerror!task_mod.DecodeTask {
        // Ordered delivery removes one completion notification per returned
        // task, which may belong to a different sequence. Switching to
        // unordered delivery would interpret those as stale notifications.
        if (self.delivery_mode == .unordered) return error.DeliveryModeMismatch;
        self.delivery_mode = .ordered;
        var selected: ?usize = null;
        for (self.slots, 0..) |slot, i| {
            if (slot.active and slot.task.sequence == self.next_delivery) {
                selected = i;
                break;
            }
        }
        const i = selected orelse {
            if (self.pending() == 0) return error.WindowEmpty;
            return error.SequenceGap;
        };
        // A task notifies exactly once before its future completes. Draining
        // one notification per delivery keeps the bounded queue live even
        // when completion order differs from sequence order.
        const task = self.popSlot(io, i) catch |err| {
            self.cancelAll(io);
            return err;
        };
        _ = self.queue.getOne(io) catch |err| {
            task.pool.cancel(task.slot_id);
            self.cancelAll(io);
            return err;
        };
        self.next_delivery += 1;
        return task;
    }

    pub fn popAny(self: *Window, io: std.Io) anyerror!task_mod.DecodeTask {
        if (self.delivery_mode == .ordered) return error.DeliveryModeMismatch;
        self.delivery_mode = .unordered;
        if (self.pending() == 0) return error.WindowEmpty;
        const done = self.queue.getOne(io) catch |err| {
            self.cancelAll(io);
            return err;
        };
        if (done.slot_id >= self.slots.len) {
            self.cancelAll(io);
            return error.InvalidCompletion;
        }
        const slot = &self.slots[done.slot_id];
        if (!slot.active or slot.generation != done.generation or slot.task.sequence != done.sequence) {
            self.cancelAll(io);
            return error.InvalidCompletion;
        }
        return self.popSlot(io, done.slot_id) catch |err| {
            self.cancelAll(io);
            return err;
        };
    }

    pub fn cancelAll(self: *Window, io: std.Io) void {
        if (self.closed) return;
        self.closed = true;
        for (&self.slots) |*slot| {
            if (slot.active) slot.task.cancel_requested.store(true, .release);
        }
        for (&self.slots) |*slot| {
            if (!slot.active) continue;
            _ = slot.task.cancelFuture(io) catch {};
            slot.task.pool.cancel(slot.task.slot_id);
            slot.active = false;
        }
        if (self.queue_initialized and !self.notification_failed.load(.acquire)) self.queue.close(io);
    }
};
