//! Reader-first parser, memory-bounded native std.Io concurrent decoding.
//!
//! Construction:
//!
//! ```zig
//! var reader: std.Io.Reader = .fixed(ply_bytes);
//! var parser = try ply.Parser.init(allocator, io, &reader, .{});
//! defer parser.deinit();
//! const header = parser.header();
//! while (try parser.next()) |batch| { ... }
//! ```
//!
//! ## Ownership contract
//!
//! | Resource                       | Owner   | Lifetime                                   |
//! |--------------------------------|---------|--------------------------------------------|
//! | Allocator implementation       | Caller  | Must outlive the parser                    |
//! | `std.Io` implementation        | Caller  | Must outlive the parser and active calls   |
//! | `std.Io.Reader`                | Caller  | Must outlive the parser                    |
//! | Underlying file/socket/memory  | Caller  | Must remain readable while parsing         |
//! | Parsed header                  | Parser  | Until `deinit`                             |
//! | Property/element names         | Parser  | Until `deinit`                             |
//! | Internal task state            | Parser       | Until joined/cancelled               |
//! | Decoded batch storage          | Parser pool  | Until all leases are released        |
//!
//! The parser stores a *borrowed* `*std.Io.Reader` pointer and a *borrowed*
//! `std.Io` interface value. It never closes, destroys, seeks, or replaces
//! the underlying source, and it never resets the reader's buffer.
//!
//! ## Reader invariants
//!
//! 1. The parser advances the caller's reader from its current logical
//!    position; a reader positioned mid-stream is supported and `body_offset`
//!    stays relative to that start position.
//! 2. The parser never closes or destroys the underlying source.
//! 3. The parser never assumes the reader supports seeking.
//! 4. The parser never replaces or resets the reader's internal buffer.
//! 5. The caller must not read from the same reader concurrently with the
//!    parser.
//! 6. Destroying the parser never reads additional bytes merely to reach
//!    EOF. When the declared records are consumed, the parser stops before
//!    any trailing data so streams may carry further structured records.
//!
//! ## Lifecycle rules
//!
//! | Operation  | Preconditions                      | Postconditions                     |
//! |------------|------------------------------------|------------------------------------|
//! | `init`     | Valid options and borrowed reader  | Header ready or error    |
//! | `header`   | Successful initialization          | Immutable metadata reference       |
//! | `next`     | Ready or reading                   | Batch, EOF, or error               |
//! | `deinit`   | Live parser                        | All parser-owned resources released|
//!
//! `next` returning `null` means *all declared records were successfully
//! consumed* — never an I/O failure; failures are errors.
//!
//! A failed `init` cleans up partial allocations before returning; the
//! caller must not (and need not) call `deinit` on a failed result.
//!
//! ## State machine
//!
//! `initializing -> ready -> reading -> completed`, or `-> failed` from any
//! non-terminal state; `deinit` moves to `destroyed` from any state.
//! Cancellation joins every native future before releasing task storage.
//!
//! ## Stable native-future ownership
//!
//! `init` returns `Parser` by value. Task descriptors, decoding buffers,
//! and the completion queue are heap-backed and stable across Parser moves.
//! Only the coordinator advances the borrowed Reader.

const std = @import("std");
const options_mod = @import("options.zig");
const header_mod = @import("format/header.zig");
const header_parser = @import("format/header_parser.zig");
const errors_mod = @import("errors.zig");
const layout_mod = @import("format/layout.zig");
const input = @import("input/root.zig");
const batch_storage = @import("batch/storage.zig");
const batch_planner = @import("batch/planner.zig");
const memory = @import("memory/root.zig");
const execution = @import("execution/root.zig");
const fault_injection = @import("testing/fault_injection.zig");
const ascii_reader_mod = @import("input/ascii_record_reader.zig");
const ascii_builder_mod = @import("input/ascii_builder.zig");
const ascii_preflight = @import("decode/ascii/preflight.zig");
const ascii_producer_mod = @import("input/ascii_producer.zig");
const ascii_decode = @import("decode/ascii/root.zig");
const binary_builder_mod = @import("input/binary_chunk_builder.zig");
const binary_boundary = @import("input/binary_boundary.zig");
const binary_preflight = @import("decode/binary/preflight.zig");

const Options = options_mod.Options;
const Header = header_mod.Header;

/// A batch of decoded records from one element.
///
/// A lease on parser-owned column storage. Release it before parser deinit.
pub const Batch = batch_storage.Batch;

/// Streaming PLY parser.
///
/// Borrowed per call site: allocator, `std.Io` implementation, and reader
/// are all caller-owned; the parser only owns its metadata (populated in
/// Phase 2) and later its buffers and task state.
pub const Parser = struct {
    const concurrent_threshold_bytes: usize = 64 * 1024;
    // Internal admission ceiling, not a worker count: std.Io decides actual
    // execution capacity and the memory budget can admit fewer tasks.
    // A fixed ceiling also bounds completion metadata for tiny chunks.
    const max_outstanding_tasks: usize = 8;
    const CompletionState = struct {
        backing: [max_outstanding_tasks]execution.Completion = undefined,
        queue: execution.task.CompletionQueue = undefined,
        failed: std.atomic.Value(bool) = .init(false),

        fn initialize(self: *CompletionState) void {
            self.failed = .init(false);
            self.queue = .init(&self.backing);
        }
    };
    const PendingTask = struct {
        task_lease: execution.Registry.Lease,
        raw_lease: ?input.pool.RawLease = null,
        ascii_bytes: []u8 = &.{},
        ascii_boundaries: []usize = &.{},
        binary_totals: []usize = &.{},
        slot_id: usize,
        sequence: u64,
    };
    /// Caller-owned; must outlive the parser. Used for all parser-owned
    /// allocations.
    allocator: std.mem.Allocator,
    memory_control: *memory.control.Control,

    /// Borrowed `std.Io` interface value. The supplied implementation must
    /// remain valid while the parser uses it.
    io: std.Io,

    /// Borrowed reader. The parser advances it from its current position;
    /// the caller retains ownership of the reader and its source.
    reader: *std.Io.Reader,

    /// Validated configuration. Copied at init; later mutation is not part
    /// of the contract.
    options: Options,

    /// Current lifecycle state. Internal; do not write directly.
    state: State = .initializing,

    /// Parser-owned header metadata and compiled layouts. Populated by a
    /// successful `init`; released by `deinit`.
    storage: header_parser.HeaderStorage,

    /// Streaming state: element/record/sequence/byte-offset progress
    /// through the body. Counters only — never pointers into this
    /// parser value, so the producer survives the parser moving after
    /// `init` returns it by value.
    producer: input.Producer = .{},

    /// Parser-owned raw input storage, allocated lazily on the first
    /// body-read request: applications that only inspect metadata never
    /// pay for it. Released by `deinit`.
    raw_buffer: input.RawBuffer,
    batch_pool: ?*batch_storage.Pool = null,
    task_registry: ?*execution.Registry = null,
    raw_pool: ?*input.pool.RawBufferPool = null,
    /// The task table and completion queue live on the heap so native
    /// futures never capture an address inside a movable Parser value.
    completions: ?*CompletionState = null,
    pending_tasks: [max_outstanding_tasks]?PendingTask = @splat(null),
    execution_stats: ExecutionStats = .{},
    input_complete: bool = false,
    /// Computed once from header and options; avoids per-batch schema walks.
    ascii_parallel: bool = false,
    deferred_error: ?NextError = null,
    /// Internal test injection only: leave null for ordinary parsing.
    test_hooks: ?*const fault_injection.Hooks = null,

    /// Sequential ASCII input retains a complete line across recoverable
    /// output-memory pressure. The reader is never touched by a decoder.
    ascii_reader: ascii_reader_mod.Reader = .{},
    ascii_progress: ascii_producer_mod.State = .{},
    ascii_stage: ascii_builder_mod.Builder = .{},
    /// A reader error discovered after valid staged records is deferred
    /// until those records have been dispatched and delivered.
    ascii_stage_terminal_error: ?NextError = null,
    ascii_preflight_split: usize = 0,
    ascii_diagnostic: ?errors_mod.Diagnostic = null,
    binary_stage: binary_builder_mod.Builder = .{},
    binary_diagnostic: ?errors_mod.Diagnostic = null,
    /// The exact last error returned by next(), with available stable
    /// source-location details. Cleared after a successful next() call.
    last_diagnostic: ?errors_mod.Diagnostic = null,

    /// Unified diagnostic snapshot for the last failed next() call.
    /// Unlike encoding-specific accessors, this also covers generic
    /// planning, memory and scheduling failures.
    pub fn lastDiagnostic(parser: *const Parser) ?errors_mod.Diagnostic {
        return parser.last_diagnostic;
    }

    /// Last failed binary-variable record's location, if available.
    pub fn binaryDiagnostic(parser: *const Parser) ?errors_mod.Diagnostic {
        return parser.binary_diagnostic;
    }

    /// Last failed ASCII record's location, if available.
    pub fn asciiDiagnostic(parser: *const Parser) ?errors_mod.Diagnostic {
        return parser.ascii_diagnostic;
    }

    /// Scheduler statistics: admitted work is not the same as work that
    /// actually ran concurrently on the caller's Io implementation.
    pub const ExecutionStats = struct {
        admitted_tasks: u64 = 0,
        native_submissions: u64 = 0,
        rejected_submissions: u64 = 0,
        inline_decodes: u64 = 0,
        max_inflight: usize = 0,
        active_decodes: usize = 0,
        max_active_decodes: usize = 0,
    };

    pub fn executionStats(parser: *const Parser) ExecutionStats {
        var stats = parser.execution_stats;
        if (parser.task_registry) |registry| {
            stats.active_decodes = registry.activity.active.load(.acquire);
            stats.max_active_decodes = registry.activity.peak.load(.acquire);
        }
        return stats;
    }

    /// Parser lifecycle states.
    pub const State = enum {
        /// Constructing; header not yet parsed.
        initializing,
        /// Header successfully parsed; `next` may be called.
        ready,
        /// Body records are being consumed.
        reading,
        /// All declared records were successfully consumed.
        completed,
        /// An error terminated the parser.
        failed,
        /// `deinit` was called; terminal.
        destroyed,
    };

    /// Errors `init` can report: configuration validation failures plus
    /// every header parsing/validation error (`InvalidMagic`,
    /// `MissingFormat`, `HeaderTooLarge`, `ReadFailed`, `OutOfMemory`,
    /// ...). The precise header error names are preserved, never
    /// collapsed into a generic "invalid header".
    pub const InitError = error{InvalidConfiguration} || errors_mod.HeaderError;

    /// Errors from planning, admission, reading, and column decoding.
    /// BatchCapacityUnavailable and allocation failures before reading can
    /// be retried without losing input.
    pub const NextError = input.ProducerError || ascii_reader_mod.RecordError || ascii_decode.record.DecodeError || binary_builder_mod.BuildError || error{
        InvalidRecordBoundary,
        CountOverflow,

        MemoryPressure,
        BatchCapacityUnavailable,
        InvalidLayout,
        InvalidColumnType,
        InvalidOutputCapacity,
    };

    /// Errors the raw streaming pipeline can report: the producer's
    /// streaming errors plus allocation/resource failures from buffer
    /// management. Phase 5 will map these into the public `Error` set
    /// with diagnostic context.
    pub const RawChunkError = input.ProducerError;

    /// Creates a parser bound to a caller-owned reader.
    ///
    /// Initialization sequence:
    ///
    /// 1. Validate `options` (an invalid configuration consumes zero
    ///    reader bytes).
    /// 2. Parse and validate the header through the borrowed reader with
    ///    bounded line reading and configured limits.
    /// 3. Compile every element's record layout.
    /// 4. Transfer the owned metadata into the parser.
    ///
    /// On success the reader is logically positioned at the first body
    /// byte and the parser is `.ready`. Any failure releases every
    /// parser-owned allocation before returning; the caller must not (and
    /// need not) call `deinit` on a failed result.
    ///
    /// Initialization is *not* transactional with respect to the reader:
    /// if a malformed header is detected after reading several lines, the
    /// reader has already advanced. The parser frees its allocations but
    /// never attempts to rewind the caller's reader.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: *std.Io.Reader,
        options: Options,
    ) InitError!Parser {
        return initImpl(allocator, io, reader, options, null);
    }

    /// Opt-in init diagnostics: unlike an instance accessor this can report
    /// malformed headers even though Parser.init() returned no Parser.
    /// `diagnostic` is borrowed only for the duration of this call; its
    /// fields own no input-buffer or native-task pointers. `code == null`
    /// denotes success. A failure leaves the reader wherever it stopped.
    pub fn initDetailed(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: *std.Io.Reader,
        options: Options,
        diagnostic: *errors_mod.Diagnostic,
    ) InitError!Parser {
        return initImpl(allocator, io, reader, options, diagnostic);
    }

    fn initImpl(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: *std.Io.Reader,
        options: Options,
        diagnostic: ?*errors_mod.Diagnostic,
    ) InitError!Parser {
        if (diagnostic) |out| out.* = .{ .category = .configuration, .stage = .configuration };
        options.validate() catch {
            if (diagnostic) |out| out.* = errors_mod.Diagnostic.fromError(error.InvalidConfiguration, .configuration);
            return error.InvalidConfiguration;
        };

        const control = memory.control.Control.create(allocator, options.memory_budget) catch |err| {
            if (diagnostic) |out| out.* = errors_mod.Diagnostic.fromError(err, .memory);
            return err;
        };
        errdefer control.destroy();
        const accounted = control.wrapper.allocator();
        const storage = header_parser.parseHeaderDetailed(accounted, reader, options, diagnostic) catch |err| {
            if (err == error.OutOfMemory and control.wrapper.budgetDenied()) {
                if (diagnostic) |out| {
                    out.code = error.ResourceLimitExceeded;
                    out.category = .resource_limit;
                    out.stage = .memory;
                    out.recovery = errors_mod.Diagnostic.recoveryFor(error.ResourceLimitExceeded);
                }
                return error.ResourceLimitExceeded;
            }
            return err;
        };
        if (diagnostic) |out| out.* = .{ .category = .header, .stage = .header };

        var enable_ascii_pipeline = false;
        if (storage.header.encoding == .ascii and options.chunk_size >= concurrent_threshold_bytes) {
            for (storage.header.elements) |element| {
                if (element.count >= 256) {
                    enable_ascii_pipeline = true;
                    break;
                }
            }
        }
        return .{
            .ascii_parallel = enable_ascii_pipeline,
            .allocator = accounted,
            .memory_control = control,
            .io = io,
            .reader = reader,
            .options = options,
            .storage = storage,
            .producer = .{},
            .raw_buffer = input.RawBuffer.init(accounted),
            .state = .ready,
        };
    }

    /// The parsed, immutable header.
    ///
    /// Precondition: successful initialization and no terminal failure
    /// (asserted, like `layouts` — a programmer-error contract, not an
    /// error path). Metadata stays queryable while the body streams.
    ///
    /// Requires no allocation, no reading, and no locking. The returned
    /// reference is owned by the parser and remains valid until `deinit`.
    pub fn header(parser: *const Parser) *const Header {
        std.debug.assert(switch (parser.state) {
            .ready, .reading, .completed => true,
            else => false,
        });
        return &parser.storage.header;
    }

    /// The compiled record layouts, one per element in header order.
    ///
    /// Precondition: successful initialization and no terminal failure
    /// (asserted, like `header`). Fixed-width and variable-width
    /// structure is distinguished per property and per element; see
    /// `ElementLayout`.
    pub fn layouts(parser: *const Parser) []const layout_mod.ElementLayout {
        std.debug.assert(switch (parser.state) {
            .ready, .reading, .completed => true,
            else => false,
        });
        return parser.storage.layouts;
    }

    /// Snapshot of allocator-visible parser-owned capacity, including the
    /// accounting controller. Does not represent total process RSS.
    pub fn memoryStats(parser: *const Parser) memory.MemoryStats {
        var result = parser.memory_control.budget.snapshot();
        result.raw_buffer_bytes = parser.raw_buffer.capacity();
        if (parser.raw_pool) |pool| result.raw_buffer_bytes += pool.capacityBytes();
        if (parser.batch_pool) |pool| {
            const breakdown = pool.memoryBreakdown();
            result.decoded_buffer_bytes = breakdown.decoded_bytes;
            result.retained_bytes = breakdown.retained_bytes;
            result.leased_bytes = breakdown.leased_bytes;
        }
        return result;
    }

    fn noteAsciiAdmissionPoint(parser: *Parser, point: fault_injection.AsciiAdmissionPoint) void {
        if (@import("builtin").is_test) {
            if (parser.test_hooks) |hooks| {
                if (hooks.ascii_admission_point) |callback| callback(hooks.context, point);
            }
        }
    }

    fn createExecutionResources(parser: *Parser) NextError!void {
        if (parser.batch_pool == null) {
            if (parser.storage.header.encoding == .ascii) parser.noteAsciiAdmissionPoint(.output_pool_create);
            parser.batch_pool = batch_storage.Pool.create(parser.allocator) catch |err| {
                if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
                return err;
            };
        }
        if (parser.raw_pool == null and parser.storage.header.encoding != .ascii and
            parser.producer.element_index < parser.storage.layouts.len and
            parser.storage.layouts[parser.producer.element_index].fixed_record_size != null)
        {
            const pool = parser.allocator.create(input.pool.RawBufferPool) catch |err| {
                if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
                return err;
            };
            errdefer parser.allocator.destroy(pool);
            pool.* = input.pool.RawBufferPool.init(parser.allocator, parser.pending_tasks.len) catch |err| {
                if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
                return err;
            };
            parser.raw_pool = pool;
        }
        if (parser.task_registry == null) {
            if (parser.storage.header.encoding == .ascii) parser.noteAsciiAdmissionPoint(.task_registry_create);
            const registry = parser.allocator.create(execution.Registry) catch |err| {
                if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
                return err;
            };
            errdefer parser.allocator.destroy(registry);
            registry.* = execution.Registry.init(parser.allocator, parser.pending_tasks.len) catch |err| {
                if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
                return err;
            };
            parser.task_registry = registry;
        }
        if (parser.completions == null and !parser.options.preserve_order) {
            if (parser.storage.header.encoding == .ascii) parser.noteAsciiAdmissionPoint(.completion_state_create);
            const c = parser.allocator.create(CompletionState) catch |err| {
                if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
                return err;
            };
            c.initialize();
            parser.completions = c;
        }
    }

    fn pendingCount(parser: *const Parser) usize {
        var count: usize = 0;
        for (parser.pending_tasks) |pending| {
            if (pending != null) count += 1;
        }
        return count;
    }

    fn smallerPlan(parser: *Parser, plan: *input.planner.ChunkPlan, width: usize) NextError!bool {
        if (plan.record_count <= 1) return false;
        parser.memory_control.budget.noteBatchReduction();
        plan.record_count = @max(@as(u64, 1), plan.record_count / 2);
        plan.byte_count = std.math.mul(u64, plan.record_count, @as(u64, @intCast(width))) catch return error.SizeOverflow;
        return true;
    }

    /// All allocations and task slots are acquired before the producer
    /// touches the borrowed reader. The producer alone advances that reader.
    fn startTask(parser: *Parser) NextError!?PendingTask {
        if (parser.input_complete) return null;
        const planned = (parser.producer.planNext(&parser.storage.header, parser.storage.layouts, parser.options) catch |err| {
            return err;
        }) orelse {
            parser.input_complete = true;
            return null;
        };
        try parser.createExecutionResources();
        const pool = parser.batch_pool.?;
        const raw_pool = parser.raw_pool.?;
        const registry = parser.task_registry.?;
        const layout = &parser.storage.layouts[planned.element_index];
        const width = layout.fixed_record_size orelse return error.InvalidLayout;
        const endian = @import("decode/binary.zig").endianFor(parser.storage.header.encoding) catch return error.UnsupportedEncoding;
        var candidate = planned;
        var attempted_raw_reclaim = false;

        while (true) {
            parser.memory_control.wrapper.clearFailure();
            const batch_plan = try batch_planner.plan(candidate, layout);
            const bytes = batch_plan.raw_bytes_required;
            const count = batch_plan.record_count;
            if (bytes > parser.options.memory_budget or batch_plan.decoded_bytes_required > parser.options.memory_budget) {
                if (!try parser.smallerPlan(&candidate, width)) return error.ResourceLimitExceeded;
                continue;
            }

            const reclaimed = pool.reclaimIncompatible(layout, count);
            if (reclaimed != 0) parser.memory_control.budget.notePoolEviction(reclaimed);
            const columns_cost = pool.estimateAdditional(layout, count) catch |err| switch (err) {
                error.OutOfMemory => return if (parser.memory_control.wrapper.budgetDenied()) error.ResourceLimitExceeded else error.OutOfMemory,
                else => return err,
            };
            const raw_cost = raw_pool.estimateAdditional(bytes);
            const additional = std.math.add(usize, columns_cost, raw_cost) catch return error.SizeOverflow;
            var reservation = parser.memory_control.budget.reserve(additional) catch |err| switch (err) {
                error.MemoryBudgetExceeded => {
                    if (!attempted_raw_reclaim) {
                        attempted_raw_reclaim = true;
                        const idle_bytes = raw_pool.reclaimIdle();
                        if (idle_bytes != 0) {
                            parser.memory_control.budget.notePoolEviction(idle_bytes);
                            continue;
                        }
                    }
                    if (!try parser.smallerPlan(&candidate, width)) return error.ResourceLimitExceeded;
                    continue;
                },
                error.ReservationCapacityExceeded => return error.ResourceLimitExceeded,
            };
            defer reservation.cancel() catch {};
            var scoped: memory.ReservedAllocator = .{
                .parent = parser.memory_control.parent,
                .reservation = &reservation,
            };
            const allocation = scoped.allocator();

            const slot = pool.acquireWithAllocator(layout, count, allocation) catch |err| {
                if (err == error.OutOfMemory and scoped.failure == .insufficient_reservation) {
                    if (!try parser.smallerPlan(&candidate, width)) return error.ResourceLimitExceeded;
                    continue;
                }
                if (err == error.OutOfMemory and scoped.failure == .underlying_allocator) return error.OutOfMemory;
                return if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) error.ResourceLimitExceeded else err;
            };
            errdefer pool.cancel(slot);

            const raw_id = raw_pool.acquireWithAllocator(bytes, allocation) catch |err| {
                if (err == error.OutOfMemory and scoped.failure == .insufficient_reservation) {
                    // An output slot is now prepared. The error defer restores
                    // it before the next invocation; no input was consumed.
                    return error.ResourceLimitExceeded;
                }
                return if (err == error.OutOfMemory and scoped.failure == .underlying_allocator) error.OutOfMemory else err;
            };
            var raw_lease: ?input.pool.RawLease = null;
            errdefer {
                if (raw_lease) |lease| {
                    raw_pool.release(lease.id, lease.generation) catch {};
                } else {
                    raw_pool.cancel(raw_id) catch {};
                }
            }
            try pool.preflight(slot, layout, bytes, count);

            // Reserve stable task identity before reading a non-seekable input.
            const lease = registry.acquire(.{
                .sequence = candidate.sequence,
                .element_index = candidate.element_index,
                .first_record = candidate.first_record,
                .byte_offset = candidate.byte_offset,
                .record_count = count,
                .input = &.{},
                .layout = layout,
                .endian = endian,
                .pool = pool,
                .slot_id = slot,
                .target = pool.target(slot),
                .activity = &registry.activity,
                .test_hooks = parser.test_hooks,
            }) catch return error.BatchCapacityUnavailable;
            errdefer registry.release(lease.id, lease.generation) catch {};

            // A read failure may advance the source by a partial chunk, but
            // cannot expose partially initialized output columns.
            _ = try parser.producer.readPlanned(
                parser.reader,
                candidate,
                raw_pool.writable(raw_id)[0..bytes],
                candidate.element_record_count,
            );
            raw_lease = raw_pool.publish(raw_id, bytes);
            const task = registry.get(lease.id, lease.generation) catch unreachable;
            task.input = raw_pool.get(raw_lease.?.id, raw_lease.?.generation) catch unreachable;
            // Ordered delivery joins futures directly. Do not enqueue
            // completion events that nobody will drain: the queue is bounded
            // and could otherwise block a worker during notify() and await().
            if (!parser.options.preserve_order) {
                const c = parser.completions.?;
                task.notification = &c.queue;
                task.notification_failure = &c.failed;
                task.notification_key = .{
                    .slot_id = lease.id,
                    .generation = lease.generation,
                    .sequence = candidate.sequence,
                };
            }
            if (bytes >= concurrent_threshold_bytes) {
                if (task.submit(parser.io)) |_| {
                    parser.execution_stats.native_submissions += 1;
                } else |_| {
                    // Concurrency may be unavailable temporarily or by design.
                    // Retain failed and successful inline results for the same
                    // completion + delivery mechanism.
                    parser.execution_stats.rejected_submissions += 1;
                    if (parser.test_hooks) |hooks| {
                        if (hooks.submission_rejected) |callback| callback(hooks.context, task.sequence);
                    }
                    parser.execution_stats.inline_decodes += 1;
                    _ = task.runInline(parser.io) catch {};
                }
            } else {
                parser.execution_stats.inline_decodes += 1;
                _ = task.runInline(parser.io) catch {};
            }
            parser.execution_stats.admitted_tasks += 1;
            parser.state = .reading;
            return .{
                .task_lease = lease,
                .raw_lease = raw_lease.?,
                .slot_id = slot,
                .sequence = candidate.sequence,
            };
        }
    }

    /// Select the next declared binary element without invoking the fixed-
    /// width planner on a list-bearing schema. The same producer sequence
    /// numbers and record counters are used by both binary task kinds.
    fn advanceBinaryElement(parser: *Parser) void {
        while (parser.producer.element_index < parser.storage.header.elements.len and
            parser.producer.next_record == parser.storage.header.elements[parser.producer.element_index].count)
        {
            parser.producer.element_index += 1;
            parser.producer.next_record = 0;
        }
    }

    fn binaryLimits(parser: *const Parser) binary_boundary.Limits {
        return .{
            .max_record_bytes = parser.options.limits.max_record_bytes,
            .max_list_items_per_record = parser.options.limits.max_list_items_per_record,
        };
    }

    fn binaryPressure(parser: *Parser, err: NextError) NextError {
        if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) {
            if (parser.pendingCount() != 0 or (parser.batch_pool != null and parser.batch_pool.?.hasLeases()))
                return error.MemoryPressure;
            return error.ResourceLimitExceeded;
        }
        return err;
    }

    fn noteBinaryReaderFailure(parser: *Parser, err: NextError) void {
        const stage = &parser.binary_stage;
        const reader_state = &stage.record_reader;
        parser.binary_diagnostic = .{
            .code = err,
            .stage = errors_mod.Diagnostic.stageFor(err),
            .category = switch (err) {
                error.TruncatedRecord, error.TruncatedListCount, error.TruncatedListPayload => .truncation,
                error.ResourceLimitExceeded, error.RecordTooLarge, error.ListTooLarge => .resource_limit,
                else => .record,
            },
            .element_index = @as(u64, @intCast(parser.producer.element_index)),
            .property_index = if (reader_state.requirement) |need| @as(u64, @intCast(need.property_index)) else null,
            .record_index = parser.producer.next_record + @as(u64, @intCast(stage.record_count)),
            .byte_offset = std.math.add(u64, parser.storage.header.body_offset, reader_state.record_start) catch null,
        };
    }

    /// Sum list counts for the selected complete prefix. This scanner
    /// performs no numeric decoding and cannot access the source reader.
    fn binaryPrefixTotals(
        parser: *Parser,
        chunk: binary_builder_mod.Chunk,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        count: usize,
        totals: []usize,
        scratch: []usize,
    ) NextError!void {
        @memset(totals, 0);
        if (count == chunk.record_count) {
            @memcpy(totals, chunk.list_item_totals);
            return;
        }
        for (0..count) |i| {
            const record = chunk.bytes[chunk.offsets[i]..chunk.offsets[i + 1]];
            const scanned = try binary_boundary.scanRecord(layout, endian, record, parser.binaryLimits(), scratch);
            switch (scanned) {
                .complete => |done| {
                    if (done.byte_length != record.len) return error.InvalidRecordBoundary;
                },
                .incomplete => return error.InvalidRecordBoundary,
            }
            for (totals, scratch) |*total, item_count| {
                total.* = std.math.add(usize, total.*, item_count) catch return error.SizeOverflow;
            }
        }
    }

    /// Admit one complete record prefix. Prepared raw bytes, boundaries and
    /// list totals belong exclusively to the task until its future is joined.
    /// The builder is changed only after every allocation has succeeded.
    fn admitBinaryVariablePrefix(parser: *Parser, count: usize) NextError!PendingTask {
        const stage = &parser.binary_stage;
        const full = stage.fill(
            parser.allocator,
            parser.reader,
            &parser.storage.layouts[parser.producer.element_index],
            @import("decode/binary.zig").endianFor(parser.storage.header.encoding) catch return error.UnsupportedEncoding,
            parser.binaryLimits(),
            parser.options.chunk_size,
            parser.producer.next_record,
            parser.storage.header.elements[parser.producer.element_index].count - parser.producer.next_record,
        ) catch |err| return err;
        const chunk = full orelse return error.InvalidBuilderState;
        if (count == 0 or count > chunk.record_count) return error.InvalidBuilderState;
        const layout = &parser.storage.layouts[chunk.element_index];
        const props = parser.storage.header.elements[chunk.element_index].properties;
        const endian = @import("decode/binary.zig").endianFor(parser.storage.header.encoding) catch return error.UnsupportedEncoding;
        const pool = parser.batch_pool.?;
        const registry = parser.task_registry.?;
        const totals = parser.allocator.alloc(usize, props.len) catch |err| return parser.binaryPressure(err);
        errdefer parser.allocator.free(totals);
        const scratch = parser.allocator.alloc(usize, props.len) catch |err| return parser.binaryPressure(err);
        defer parser.allocator.free(scratch);
        try parser.binaryPrefixTotals(chunk, layout, endian, count, totals, scratch);
        const end = chunk.offsets[count];
        const prefix: binary_builder_mod.Chunk = .{
            .element_index = chunk.element_index,
            .first_record = chunk.first_record,
            .record_count = count,
            .first_body_byte_offset = chunk.first_body_byte_offset,
            .bytes = chunk.bytes[0..end],
            .offsets = chunk.offsets[0 .. count + 1],
            .list_item_totals = totals,
        };
        const planned = try binary_preflight.plan(prefix, layout);
        if (planned.decoded_bytes > parser.options.memory_budget) return error.ResourceLimitExceeded;
        const raw = parser.allocator.dupe(u8, prefix.bytes) catch |err| return parser.binaryPressure(err);
        errdefer parser.allocator.free(raw);
        const boundaries = parser.allocator.dupe(usize, prefix.offsets) catch |err| return parser.binaryPressure(err);
        errdefer parser.allocator.free(boundaries);
        // Reclaim idle, incompatible output when useful. Never touch a
        // leased, filling or ready slot.
        const slot = pool.acquireBinaryVariableSized(layout, props, count, totals) catch |err| {
            return parser.binaryPressure(switch (err) {
                error.InvalidLayout => error.InvalidLayout,
                error.SizeOverflow => error.SizeOverflow,
                error.BatchCapacityUnavailable => error.BatchCapacityUnavailable,
                else => error.OutOfMemory,
            });
        };
        errdefer pool.cancel(slot);
        const absolute_offset = std.math.add(u64, parser.storage.header.body_offset, chunk.first_body_byte_offset) catch return error.SizeOverflow;
        const lease = registry.acquire(.{
            .sequence = parser.producer.sequence,
            .element_index = chunk.element_index,
            .first_record = chunk.first_record,
            .byte_offset = absolute_offset,
            .record_count = count,
            .input = raw,
            .layout = layout,
            .endian = endian,
            .encoding = .binary_variable,
            .binary_boundaries = boundaries,
            .binary_totals = totals,
            .pool = pool,
            .slot_id = slot,
            .target = pool.target(slot),
            .activity = &registry.activity,
            .test_hooks = parser.test_hooks,
        }) catch return error.BatchCapacityUnavailable;
        errdefer registry.release(lease.id, lease.generation) catch {};
        const task = registry.get(lease.id, lease.generation) catch unreachable;
        if (!parser.options.preserve_order) {
            const c = parser.completions.?;
            task.notification = &c.queue;
            task.notification_failure = &c.failed;
            task.notification_key = .{ .slot_id = lease.id, .generation = lease.generation, .sequence = task.sequence };
        }
        if (raw.len >= concurrent_threshold_bytes) {
            if (task.submit(parser.io)) |_| {
                parser.execution_stats.native_submissions += 1;
            } else |_| {
                parser.execution_stats.rejected_submissions += 1;
                parser.execution_stats.inline_decodes += 1;
                _ = task.runInline(parser.io) catch {};
            }
        } else {
            parser.execution_stats.inline_decodes += 1;
            _ = task.runInline(parser.io) catch {};
        }
        parser.execution_stats.admitted_tasks += 1;
        stage.consumePrefix(count, totals);
        parser.producer.next_record += @as(u64, @intCast(count));
        parser.producer.sequence += 1;
        parser.producer.body_bytes_consumed = stage.record_reader.body_bytes_consumed;
        parser.producer.state = .reading;
        parser.state = .reading;
        return .{
            .task_lease = lease,
            .slot_id = slot,
            .sequence = task.sequence,
            .ascii_bytes = raw,
            .ascii_boundaries = boundaries,
            .binary_totals = totals,
        };
    }

    fn startBinaryVariableTask(parser: *Parser) NextError!?PendingTask {
        const idx = parser.producer.element_index;
        const layout = &parser.storage.layouts[idx];
        const endian = @import("decode/binary.zig").endianFor(parser.storage.header.encoding) catch return error.UnsupportedEncoding;
        try parser.createExecutionResources();
        // Synchronize after fixed-size elements. Synchronization cannot
        // rewind or touch an in-progress variable record.
        if (!parser.binary_stage.active and !parser.binary_stage.ready and !parser.binary_stage.pending and
            !parser.binary_stage.record_reader.in_progress)
        {
            try parser.binary_stage.synchronizeBodyOffset(parser.producer.body_bytes_consumed);
        }
        while (true) {
            parser.memory_control.wrapper.clearFailure();
            const result = parser.binary_stage.fill(
                parser.allocator,
                parser.reader,
                layout,
                endian,
                parser.binaryLimits(),
                parser.options.chunk_size,
                parser.producer.next_record,
                parser.storage.header.elements[idx].count - parser.producer.next_record,
            ) catch |err| {
                const mapped = parser.binaryPressure(err);
                if (mapped == error.ResourceLimitExceeded or mapped == error.MemoryPressure) {
                    const reclaimed = parser.batch_pool.?.reclaimAvailable();
                    if (reclaimed != 0) {
                        parser.memory_control.budget.notePoolEviction(reclaimed);
                        continue;
                    }
                }
                if (mapped != error.MemoryPressure and mapped != error.ResourceLimitExceeded and mapped != error.OutOfMemory)
                    parser.noteBinaryReaderFailure(mapped);
                return mapped;
            };
            const chunk = result orelse return error.InvalidBuilderState;
            var attempt = chunk.record_count;
            while (true) {
                const pending = parser.admitBinaryVariablePrefix(attempt) catch |err| {
                    if (err == error.MemoryPressure or err == error.ResourceLimitExceeded) {
                        const reclaimed = parser.batch_pool.?.reclaimAvailable();
                        if (reclaimed != 0) {
                            parser.memory_control.budget.notePoolEviction(reclaimed);
                            continue;
                        }
                    }
                    if ((err == error.MemoryPressure or err == error.ResourceLimitExceeded or err == error.BatchCapacityUnavailable) and attempt > 1) {
                        attempt = @max(@as(usize, 1), attempt / 2);
                        parser.memory_control.budget.noteBatchReduction();
                        continue;
                    }
                    return err;
                };
                return pending;
            }
        }
    }

    fn startBinaryTask(parser: *Parser) NextError!?PendingTask {
        if (parser.input_complete) return null;
        parser.advanceBinaryElement();
        if (parser.producer.element_index >= parser.storage.header.elements.len) {
            parser.input_complete = true;
            parser.producer.state = .completed;
            return null;
        }
        const layout = &parser.storage.layouts[parser.producer.element_index];
        if (layout.fixed_record_size == null) return parser.startBinaryVariableTask();
        return parser.startTask();
    }

    fn asciiTokenAbsoluteOffset(record_start: ?u64, token_offset: ?usize) ?u64 {
        const start = record_start orelse return null;
        const relative = token_offset orelse return null;
        return std.math.add(u64, start, @as(u64, @intCast(relative))) catch null;
    }

    /// Reclaim cached decoded buffers only after an ASCII admission hits
    /// actual budget pressure. The staged bytes and reader scratch survive
    /// retries, and no leased/filling/ready output can be evicted.
    fn reclaimIdleAsciiOutput(parser: *Parser) bool {
        const pool = parser.batch_pool orelse return false;
        const bytes = pool.reclaimAvailable();
        if (bytes == 0) return false;
        parser.memory_control.budget.notePoolEviction(bytes);
        return true;
    }

    fn mapAsciiPressure(parser: *Parser, err: NextError) NextError {
        if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) {
            if (parser.pendingCount() > 0 or (parser.batch_pool != null and parser.batch_pool.?.hasLeases())) {
                return error.MemoryPressure;
            }
            return error.ResourceLimitExceeded;
        }
        return err;
    }

    fn asciiChunkError(parser: *Parser, err: NextError, f: ascii_preflight.Failure) NextError {
        const stage = &parser.ascii_stage;
        const absolute_start: ?u64 = std.math.add(u64, parser.storage.header.body_offset, stage.body_offset) catch null;
        const record_off: ?u64 = if (f.record_index < stage.record_count and absolute_start != null)
            std.math.add(u64, absolute_start.?, @as(u64, @intCast(stage.offsets.items[f.record_index]))) catch null
        else
            absolute_start;
        parser.ascii_diagnostic = .{
            .code = err,
            .stage = errors_mod.Diagnostic.stageFor(err),
            .category = switch (err) {
                error.TruncatedAsciiBody => .truncation,
                error.ResourceLimitExceeded, error.RecordTooLarge, error.ListTooLarge, error.TokenTooLong => .resource_limit,
                else => .record,
            },
            .element_index = @intCast(stage.element_index),
            .property_index = if (f.property_index) |index| @intCast(index) else null,
            .record_index = stage.first_record + @as(u64, @intCast(f.record_index)),
            .line_number = stage.first_line_number + @as(u64, @intCast(f.record_index)),
            .byte_offset = record_off,
            .token_byte_offset = asciiTokenAbsoluteOffset(record_off, f.token_offset),
        };
        parser.state = .failed;
        return err;
    }

    fn fillAsciiStage(parser: *Parser) NextError!bool {
        const stage = &parser.ascii_stage;
        if (stage.record_count != 0) return true;
        if (parser.ascii_stage_terminal_error) |err| {
            parser.state = .failed;
            return err;
        }
        parser.advanceAsciiElement();
        if (parser.producer.element_index == parser.storage.header.elements.len) {
            parser.input_complete = true;
            return false;
        }
        const element_index = parser.producer.element_index;
        const element = &parser.storage.header.elements[element_index];
        stage.begin(
            element_index,
            parser.producer.next_record,
            // A budget failure can leave the line reader mid-record even
            // when no complete record is marked pending. The original line
            // start, not the advanced physical cursor, anchors diagnostics.
            if (parser.ascii_progress.pending_record or parser.ascii_reader.in_progress) parser.ascii_reader.last_start else parser.ascii_reader.body_bytes_consumed,
            if (parser.ascii_progress.pending_record or parser.ascii_reader.in_progress) parser.ascii_reader.last_line_number else parser.ascii_reader.line_number + 1,
        );
        const max_chunk = @min(parser.options.chunk_size, @min(@as(usize, 1024 * 1024), @max(@as(usize, 256), parser.options.memory_budget / 16)));
        const remaining = element.count - parser.producer.next_record;
        while (@as(u64, @intCast(stage.record_count)) < remaining) {
            if (stage.record_count != 0 and stage.bytes.items.len >= max_chunk) break;
            parser.memory_control.wrapper.clearFailure();
            if (!parser.ascii_progress.pending_record) {
                parser.noteAsciiAdmissionPoint(.record_scratch);
                _ = parser.ascii_reader.readRecord(parser.allocator, parser.reader, parser.options.limits.max_ascii_record_bytes) catch |err| {
                    if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) {
                        // The reader retains the partial line and the byte that
                        // failed to append. First dispatch any complete staged
                        // records; otherwise a held lease or in-flight task may
                        // release the memory needed to resume this same line.
                        if (stage.record_count != 0) return true;
                        return parser.mapAsciiPressure(error.OutOfMemory);
                    }
                    const mapped: NextError = err;
                    const failure = parser.asciiFail(mapped, null, stage.first_record + @as(u64, @intCast(stage.record_count)), element_index, null);
                    if (stage.record_count != 0) {
                        parser.ascii_stage_terminal_error = failure;
                        parser.state = .reading;
                        return true;
                    }
                    return failure;
                };
                parser.ascii_progress.pending_record = true;
            }
            const raw_length = std.math.cast(usize, parser.ascii_reader.body_bytes_consumed - parser.ascii_reader.last_start) orelse return error.SizeOverflow;
            if (stage.record_count != 0 and raw_length > max_chunk - @min(max_chunk, stage.bytes.items.len)) {
                // Keep the newly read complete line in the reader scratch.
                // The next chunk starts at its original source byte offset.
                return true;
            }
            const record: ascii_reader_mod.RecordView = .{
                .bytes = parser.ascii_reader.scratch.items,
                .body_offset = parser.ascii_reader.last_start,
                .line_number = parser.ascii_reader.last_line_number,
            };
            stage.appendWithHooks(parser.allocator, record, raw_length, parser.test_hooks) catch |err| {
                const mapped: NextError = switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidAsciiRecord => error.InvalidAsciiRecord,
                    error.SizeOverflow => error.SizeOverflow,
                };
                if (stage.record_count != 0 and err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) {
                    return true;
                }
                return parser.mapAsciiPressure(mapped);
            };
            parser.ascii_progress.pending_record = false;
        }
        return stage.record_count != 0;
    }

    /// Prepare an exact independent prefix. All fallible allocations happen
    /// before consuming the staged prefix. On failure it remains intact.
    fn admitAsciiPrefix(parser: *Parser, count: usize) NextError!PendingTask {
        const stage = &parser.ascii_stage;
        const element_index = stage.element_index;
        const props = parser.storage.header.elements[element_index].properties;
        const layout = &parser.storage.layouts[element_index];
        const pool = parser.batch_pool.?;
        const registry = parser.task_registry.?;
        parser.noteAsciiAdmissionPoint(.preflight_totals);
        const totals = parser.allocator.alloc(usize, props.len) catch |err| return parser.mapAsciiPressure(err);
        defer parser.allocator.free(totals);
        @memset(totals, 0);
        var has_lists = false;
        for (props) |prop| {
            if (prop.kind == .list) has_lists = true;
        }
        var failure: ascii_preflight.Failure = .{};
        if (has_lists) {
            _ = ascii_preflight.scan(props, stage.bytes.items[0..stage.offsets.items[count]], stage.offsets.items[0 .. count + 1], parser.options.limits.max_ascii_token_bytes, parser.options.limits.max_list_items_per_record, totals, &failure) catch |err| {
                if (failure.record_index != 0) {
                    parser.ascii_preflight_split = failure.record_index;
                    return error.BatchCapacityUnavailable;
                }
                return parser.asciiChunkError(err, failure);
            };
        }
        parser.memory_control.wrapper.clearFailure();
        parser.noteAsciiAdmissionPoint(.raw_copy);
        const raw = parser.allocator.dupe(u8, stage.bytes.items[0..stage.offsets.items[count]]) catch |err| return parser.mapAsciiPressure(err);
        errdefer parser.allocator.free(raw);
        parser.noteAsciiAdmissionPoint(.boundary_copy);
        const boundaries = parser.allocator.dupe(usize, stage.offsets.items[0 .. count + 1]) catch |err| return parser.mapAsciiPressure(err);
        errdefer parser.allocator.free(boundaries);
        const reclaimed = pool.reclaimIncompatibleAsciiSized(layout, props, count, totals);
        if (reclaimed != 0) parser.memory_control.budget.notePoolEviction(reclaimed);
        parser.memory_control.wrapper.clearFailure();
        parser.noteAsciiAdmissionPoint(.output_storage);
        const slot = pool.acquireAsciiSized(layout, props, count, totals) catch |err| {
            const mapped: NextError = switch (err) {
                error.InvalidLayout => error.InvalidLayout,
                error.BatchCapacityUnavailable => error.BatchCapacityUnavailable,
                error.SizeOverflow => error.SizeOverflow,
                else => error.OutOfMemory,
            };
            return parser.mapAsciiPressure(mapped);
        };
        errdefer pool.cancel(slot);
        const task_offset = std.math.add(u64, parser.storage.header.body_offset, stage.body_offset) catch return error.SizeOverflow;
        const lease = registry.acquire(.{
            .sequence = parser.producer.sequence,
            .element_index = element_index,
            .first_record = stage.first_record,
            .byte_offset = task_offset,
            .record_count = count,
            .input = raw,
            .layout = layout,
            .endian = .little,
            .encoding = .ascii,
            .ascii_boundaries = boundaries,
            .ascii_properties = props,
            .ascii_token_limit = parser.options.limits.max_ascii_token_bytes,
            .ascii_item_limit = parser.options.limits.max_list_items_per_record,
            .ascii_first_line_number = stage.first_line_number,
            .pool = pool,
            .slot_id = slot,
            .target = pool.target(slot),
            .activity = &registry.activity,
            .test_hooks = parser.test_hooks,
        }) catch return error.BatchCapacityUnavailable;
        errdefer registry.release(lease.id, lease.generation) catch {};
        const task = registry.get(lease.id, lease.generation) catch unreachable;
        // Just as for binary tasks, only unordered delivery consumes the
        // bounded completion queue. Ordered tasks are awaited by sequence.
        if (!parser.options.preserve_order) {
            const completion = parser.completions.?;
            task.notification = &completion.queue;
            task.notification_failure = &completion.failed;
            task.notification_key = .{
                .slot_id = lease.id,
                .generation = lease.generation,
                .sequence = parser.producer.sequence,
            };
        }
        // All required state is now owned by the task. Failure in the worker
        // is reported through the normal completion mechanism.
        if (raw.len >= concurrent_threshold_bytes) {
            if (task.submit(parser.io)) |_| {
                parser.execution_stats.native_submissions += 1;
            } else |_| {
                parser.execution_stats.rejected_submissions += 1;
                parser.execution_stats.inline_decodes += 1;
                _ = task.runInline(parser.io) catch {};
            }
        } else {
            parser.execution_stats.inline_decodes += 1;
            _ = task.runInline(parser.io) catch {};
        }
        parser.execution_stats.admitted_tasks += 1;
        stage.consumePrefix(count);
        parser.producer.next_record += @intCast(count);
        parser.producer.sequence += 1;
        parser.producer.body_bytes_consumed = stage.body_offset;
        parser.state = .reading;
        return .{
            .task_lease = lease,
            .slot_id = slot,
            .sequence = task.sequence,
            .ascii_bytes = raw,
            .ascii_boundaries = boundaries,
        };
    }

    fn startAsciiTask(parser: *Parser) NextError!?PendingTask {
        if (parser.input_complete) return null;
        try parser.createExecutionResources();
        // A released batch stays cached until reclaimed. If even the raw
        // record reader cannot grow, evict idle output and retry the exact
        // partial line rather than returning permanent resource failure.
        while (true) {
            const has_records = parser.fillAsciiStage() catch |err| {
                if ((err == error.MemoryPressure or err == error.ResourceLimitExceeded) and
                    parser.state != .failed and parser.reclaimIdleAsciiOutput()) continue;
                return err;
            };
            if (!has_records) return null;
            break;
        }
        var attempt = parser.ascii_stage.record_count;
        while (true) {
            const pending = parser.admitAsciiPrefix(attempt) catch |err| {
                // Raw/boundary copies are allocated *before* schema-specific
                // pool reclamation. An idle compatible batch can therefore
                // block admission unless we explicitly evict it and retry.
                if ((err == error.MemoryPressure or err == error.ResourceLimitExceeded) and
                    parser.state != .failed and parser.reclaimIdleAsciiOutput()) continue;
                if (parser.ascii_preflight_split != 0) {
                    attempt = parser.ascii_preflight_split;
                    parser.ascii_preflight_split = 0;
                    continue;
                }
                if ((err == error.MemoryPressure or err == error.ResourceLimitExceeded or err == error.BatchCapacityUnavailable) and attempt > 1) {
                    attempt = @max(@as(usize, 1), attempt / 2);
                    parser.memory_control.budget.noteBatchReduction();
                    continue;
                }
                return err;
            };
            return pending;
        }
    }

    fn noteAsciiTaskFailure(parser: *Parser, task: *const execution.task.DecodeTask, err: anyerror) void {
        const location = task.failure_info orelse return;
        const record_start: ?u64 = std.math.add(u64, task.byte_offset, @as(u64, @intCast(task.ascii_boundaries[location.record_index]))) catch null;
        parser.ascii_diagnostic = .{
            .code = err,
            .stage = errors_mod.Diagnostic.stageFor(err),
            .category = switch (err) {
                error.TruncatedAsciiBody => .truncation,
                error.ResourceLimitExceeded, error.RecordTooLarge, error.TokenTooLong, error.ListTooLarge => .resource_limit,
                else => .record,
            },
            .element_index = @intCast(task.element_index),
            .property_index = if (location.property_index) |i| @intCast(i) else null,
            .record_index = task.first_record + @as(u64, @intCast(location.record_index)),
            .line_number = task.ascii_first_line_number + @as(u64, @intCast(location.record_index)),
            .byte_offset = record_start,
            .token_byte_offset = asciiTokenAbsoluteOffset(record_start, location.token_offset),
        };
    }

    fn reclaimPending(parser: *Parser, pending: PendingTask, success: bool) void {
        // The future is joined before this function is invoked. No worker
        // can access its raw bytes, column buffers, or registry entry now.
        if (pending.raw_lease) |raw_lease| {
            parser.raw_pool.?.release(raw_lease.id, raw_lease.generation) catch @panic("invalid raw lease");
        } else {
            parser.allocator.free(pending.ascii_bytes);
            parser.allocator.free(pending.ascii_boundaries);
            if (pending.binary_totals.len != 0) parser.allocator.free(pending.binary_totals);
        }
        if (!success) parser.batch_pool.?.cancel(pending.slot_id);
        parser.task_registry.?.release(pending.task_lease.id, pending.task_lease.generation) catch @panic("invalid task lease");
    }

    fn finishTask(parser: *Parser, index: usize) NextError!Batch {
        const pending = parser.pending_tasks[index].?;
        parser.pending_tasks[index] = null;
        const task = parser.task_registry.?.get(pending.task_lease.id, pending.task_lease.generation) catch unreachable;
        const result = task.await(parser.io);
        if (result) |_| {
            parser.batch_pool.?.publishReady(pending.slot_id, .{
                .element_index = task.element_index,
                .first_record = task.first_record,
                .record_count = task.record_count,
                .sequence = task.sequence,
            });
            const batch = parser.batch_pool.?.leaseReady(pending.slot_id);
            parser.reclaimPending(pending, true);
            return batch;
        } else |err| {
            if (task.encoding == .ascii) parser.noteAsciiTaskFailure(task, err);
            if (task.encoding == .binary_variable) parser.binary_diagnostic = .{
                .code = err,
                .stage = .decode,
                .chunk_sequence = task.sequence,
                .category = .record,
                .element_index = @as(u64, @intCast(task.element_index)),
                .record_index = task.first_record,
                .byte_offset = task.byte_offset,
            };
            parser.reclaimPending(pending, false);
            parser.cancelPending();
            parser.state = .failed;
            return switch (err) {
                error.Cancelled => error.InvalidProducerState,
                error.InvalidLayout => error.InvalidLayout,
                error.InvalidColumnType => error.InvalidColumnType,
                error.InvalidOutputCapacity => error.InvalidOutputCapacity,
                error.InvalidRecordBoundary => error.InvalidRecordBoundary,
                error.CountOverflow => error.CountOverflow,
                error.SizeOverflow => error.SizeOverflow,
                error.InvalidAsciiRecord => error.InvalidAsciiRecord,
                error.MissingValue => error.MissingValue,
                error.UnexpectedValue => error.UnexpectedValue,
                error.InvalidNumber => error.InvalidNumber,
                error.IntegerOverflow => error.IntegerOverflow,
                error.FloatOverflow => error.FloatOverflow,
                error.NegativeListCount => error.NegativeListCount,
                error.InvalidListCount => error.InvalidListCount,
                error.ListTooLarge => error.ListTooLarge,
                error.TokenTooLong => error.TokenTooLong,
                else => error.InvalidProducerState,
            };
        }
    }

    fn cancelPending(parser: *Parser) void {
        const registry = parser.task_registry orelse return;
        // Signal every worker before joining any of them.
        var had_pending = false;
        for (parser.pending_tasks) |item| {
            if (item) |p| {
                had_pending = true;
                if (registry.get(p.task_lease.id, p.task_lease.generation)) |task| {
                    task.cancel_requested.store(true, .release);
                } else |_| {}
            }
        }
        if (@import("builtin").is_test and had_pending) {
            if (parser.test_hooks) |hooks| {
                if (hooks.after_cancel_signal) |callback| callback(hooks.context);
            }
        }
        for (&parser.pending_tasks) |*item| {
            if (item.*) |p| {
                if (registry.get(p.task_lease.id, p.task_lease.generation)) |task| {
                    _ = task.cancelFuture(parser.io) catch {};
                } else |_| {}
                parser.reclaimPending(p, false);
                item.* = null;
            }
        }
    }

    fn asciiFail(parser: *Parser, err: NextError, property_index: ?usize, record_index: u64, element_index: usize, token_offset: ?usize) NextError {
        parser.ascii_diagnostic = .{
            .code = err,
            .stage = errors_mod.Diagnostic.stageFor(err),
            .category = switch (err) {
                error.TruncatedAsciiBody => .truncation,
                error.ResourceLimitExceeded, error.RecordTooLarge, error.TokenTooLong, error.ListTooLarge => .resource_limit,
                else => .record,
            },
            .element_index = @as(u64, @intCast(element_index)),
            .property_index = if (property_index) |i| @as(u64, @intCast(i)) else null,
            .record_index = record_index,
            .line_number = parser.ascii_reader.last_line_number,
            .byte_offset = std.math.add(u64, parser.storage.header.body_offset, parser.ascii_reader.last_start) catch null,
            .token_byte_offset = if (token_offset) |off| blk: {
                const record_start = std.math.add(u64, parser.storage.header.body_offset, parser.ascii_reader.last_start) catch break :blk null;
                break :blk std.math.add(u64, record_start, @as(u64, @intCast(off))) catch null;
            } else null,
        };
        parser.state = .failed;
        return err;
    }

    fn ensureAsciiPool(parser: *Parser) NextError!*batch_storage.Pool {
        if (parser.batch_pool) |pool| return pool;
        const pool = batch_storage.Pool.create(parser.allocator) catch |err| {
            if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
            return err;
        };
        parser.batch_pool = pool;
        return pool;
    }

    fn advanceAsciiElement(parser: *Parser) void {
        while (parser.producer.element_index < parser.storage.header.elements.len and
            parser.producer.next_record == parser.storage.header.elements[parser.producer.element_index].count)
        {
            parser.producer.element_index += 1;
            parser.producer.next_record = 0;
        }
    }

    /// Sequential strict ASCII records; no native task submission (Phase 9).
    /// Scalar output is admitted before reading. List output is admitted
    /// after one complete bounded record has been staged; when pressure
    /// prevents admission, the line remains available for retry.
    fn nextAscii(parser: *Parser) NextError!?Batch {
        parser.advanceAsciiElement();
        if (parser.producer.element_index == parser.storage.header.elements.len) {
            parser.state = .completed;
            return null;
        }
        const element_index = parser.producer.element_index;
        const element = &parser.storage.header.elements[element_index];
        const layout = &parser.storage.layouts[element_index];
        const first_record = parser.producer.next_record;
        const first_offset = parser.ascii_reader.body_bytes_consumed;
        const props = element.properties;
        var has_lists = false;
        for (props) |prop| {
            if (prop.kind == .list) has_lists = true;
        }

        const pool = try parser.ensureAsciiPool();
        const rest = element.count - first_record;
        const min_bytes = @max(@as(usize, 1), layout.minimum_record_size);
        // Lists initially use one-record batches so unknown list payload
        // capacity is never pre-committed from an untrusted count.
        var capacity: usize = if (has_lists) 1 else @max(@as(usize, 1), @min(@as(usize, 4096), parser.options.chunk_size / min_bytes));
        capacity = @min(capacity, std.math.cast(usize, rest) orelse capacity);
        var id: usize = undefined;
        // For lists, retain the complete staged line across any recoverable
        // output-capacity rejection. Scalar records are read only after slot
        // admission succeeds, preserving the phase-6 no-consumption rule.
        if (has_lists and !parser.ascii_progress.pending_record) {
            parser.memory_control.wrapper.clearFailure();
            _ = parser.ascii_reader.readRecord(parser.allocator, parser.reader, parser.options.limits.max_ascii_record_bytes) catch |err| {
                if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied() and pool.hasLeases()) {
                    // The line reader retains the partial record. A consumer
                    // can release an earlier batch, then retry this same line.
                    return error.MemoryPressure;
                }
                return parser.asciiFail(if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) error.ResourceLimitExceeded else err, null, first_record, element_index, null);
            };
            parser.ascii_progress.pending_record = true;
        }
        while (true) {
            parser.memory_control.wrapper.clearFailure();
            // Available incompatible storage can be reclaimed, but never a
            // filling or consumer-leased slot.
            const reclaimed = pool.reclaimIncompatibleAscii(layout, props, capacity);
            if (reclaimed != 0) parser.memory_control.budget.notePoolEviction(reclaimed);
            id = pool.acquireAscii(layout, props, capacity, parser.allocator) catch |err| {
                const budget_denied = parser.memory_control.wrapper.budgetDenied();
                if (!has_lists and budget_denied and capacity > 1) {
                    capacity = @max(1, capacity / 2);
                    parser.memory_control.budget.noteBatchReduction();
                    continue;
                }
                if (err == error.OutOfMemory and budget_denied) {
                    if (pool.hasLeases()) return error.MemoryPressure;
                    return parser.asciiFail(error.ResourceLimitExceeded, null, first_record, element_index, null);
                }
                return switch (err) {
                    error.InvalidLayout => error.InvalidLayout,
                    error.BatchCapacityUnavailable => error.BatchCapacityUnavailable,
                    error.SizeOverflow => error.SizeOverflow,
                    else => error.OutOfMemory,
                };
            };
            break;
        }
        var commit = false;
        defer if (!commit) pool.cancel(id);
        var n: usize = 0;
        const token_limit = parser.options.limits.max_ascii_token_bytes;
        const list_limit = parser.options.limits.max_list_items_per_record;
        var raw_bytes: u64 = 0;
        while (n < capacity) {
            if (!parser.ascii_progress.pending_record) {
                parser.memory_control.wrapper.clearFailure();
                _ = parser.ascii_reader.readRecord(parser.allocator, parser.reader, parser.options.limits.max_ascii_record_bytes) catch |err| {
                    if (has_lists and err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied() and pool.hasLeases()) {
                        return error.MemoryPressure;
                    }
                    return parser.asciiFail(if (err == error.OutOfMemory and parser.memory_control.wrapper.budgetDenied()) error.ResourceLimitExceeded else err, null, first_record + @as(u64, @intCast(n)), element_index, null);
                };
                parser.ascii_progress.pending_record = true;
            }
            // This is an unpublished slot; partial writes are invisible.
            var failed_property: ?usize = null;
            var failed_token_offset: ?usize = null;
            pool.decodeAsciiRecord(id, props, parser.ascii_reader.scratch.items, n, token_limit, list_limit, &failed_property, &failed_token_offset) catch |err| {
                if (err == error.OutOfMemory) {
                    // The line stays staged. A consumer can release other
                    // batches before retrying this record. List batches are
                    // one record long, so no successful prefix is lost.
                    if (has_lists and parser.memory_control.wrapper.budgetDenied()) {
                        if (pool.hasLeases()) return error.MemoryPressure;
                        return parser.asciiFail(error.ResourceLimitExceeded, failed_property, first_record + @as(u64, @intCast(n)), element_index, failed_token_offset);
                    }
                    if (has_lists) return parser.asciiFail(error.OutOfMemory, failed_property, first_record + @as(u64, @intCast(n)), element_index, failed_token_offset);
                }
                return parser.asciiFail(switch (err) {
                    error.InvalidLayout => error.InvalidLayout,
                    error.InvalidOutputCapacity => error.InvalidOutputCapacity,
                    error.InvalidColumnType => error.InvalidColumnType,
                    error.OutOfMemory => error.OutOfMemory,
                    error.MissingValue => error.MissingValue,
                    error.UnexpectedValue => error.UnexpectedValue,
                    error.InvalidNumber => error.InvalidNumber,
                    error.IntegerOverflow => error.IntegerOverflow,
                    error.FloatOverflow => error.FloatOverflow,
                    error.NegativeListCount => error.NegativeListCount,
                    error.InvalidListCount => error.InvalidListCount,
                    error.ListTooLarge => error.ListTooLarge,
                    error.TokenTooLong => error.TokenTooLong,
                    error.InvalidAsciiRecord => error.InvalidAsciiRecord,
                }, failed_property, first_record + @as(u64, @intCast(n)), element_index, failed_token_offset);
            };
            parser.ascii_progress.pending_record = false;
            n += 1;
            raw_bytes = parser.ascii_reader.body_bytes_consumed - first_offset;
            if (@as(u64, @intCast(n)) >= rest or raw_bytes >= @as(u64, @intCast(parser.options.chunk_size))) break;
        }
        // Retarget scalar column views to the initialized prefix. The
        // record decoder already populated them at each completed row.
        pool.publishReady(id, .{
            .element_index = element_index,
            .first_record = first_record,
            .record_count = n,
            .sequence = parser.producer.sequence,
        });
        const batch = pool.leaseReady(id);
        commit = true;
        parser.producer.next_record += @intCast(n);
        parser.producer.sequence += 1;
        parser.producer.body_bytes_consumed = parser.ascii_reader.body_bytes_consumed;
        parser.state = .reading;
        parser.ascii_progress.batches += 1;
        return batch;
    }

    /// Return one complete lease, or null after all declared records are
    /// delivered. Source errors discovered during read-ahead are deferred
    /// behind previously admitted ordered batches. Memory-pressure errors
    /// never discard a staged, complete chunk of the caller's input.
    pub fn next(parser: *Parser) NextError!?Batch {
        const result = parser.nextImpl() catch |err| {
            const existing: ?errors_mod.Diagnostic = switch (parser.storage.header.encoding) {
                .ascii => parser.ascii_diagnostic,
                .binary_little_endian, .binary_big_endian => parser.binary_diagnostic,
            };
            var snapshot = errors_mod.Diagnostic.fromError(err, errors_mod.Diagnostic.stageFor(err));
            if (existing) |located| {
                // Only attach an encoding-specific location when it belongs
                // to the exact returned error, not an earlier retry.
                if (located.code != null and located.code.? == err) {
                    snapshot = located;
                    snapshot.code = err;
                }
            }
            // A location-specific diagnostic may have been constructed by an
            // older decoding path. Keep its source position but always apply
            // the same recovery taxonomy as the generic path.
            snapshot.category = errors_mod.Diagnostic.categoryFor(err);
            snapshot.recovery = errors_mod.Diagnostic.recoveryFor(err);
            parser.last_diagnostic = snapshot;
            return err;
        };
        parser.last_diagnostic = null;
        return result;
    }

    fn nextImpl(parser: *Parser) NextError!?Batch {
        switch (parser.state) {
            .ready, .reading => {},
            .completed => return null,
            else => return error.InvalidProducerState,
        }
        if (parser.storage.header.encoding == .ascii and !parser.ascii_parallel) return parser.nextAscii();
        while (parser.pendingCount() < parser.pending_tasks.len and !parser.input_complete and parser.deferred_error == null) {
            const pending = (if (parser.storage.header.encoding == .ascii) parser.startAsciiTask() else parser.startBinaryTask()) catch |err| {
                if (parser.test_hooks) |hooks| {
                    if (hooks.admission_failure) |callback| callback(hooks.context, err);
                }
                if (parser.pendingCount() > 0) {
                    if (err != error.ResourceLimitExceeded and err != error.BatchCapacityUnavailable and err != error.MemoryPressure) {
                        parser.deferred_error = err;
                    }
                    // A later staged ASCII record can fail while earlier
                    // tasks are still running. Preserve prefix delivery and
                    // only report the terminal failure after those tasks.
                    if (parser.state == .failed) parser.state = .reading;
                    break;
                }
                // A fixed-width record above max_record_bytes can never
                // become valid on retry. Likewise, once there are no pending
                // tasks or consumer-held leases to release, binary budget
                // refusal is permanent for the current parser configuration.
                // In both cases no new input was consumed by admission.
                const permanent_binary_resource = parser.storage.header.encoding != .ascii and
                    (err == error.RecordTooLarge or
                        (err == error.ResourceLimitExceeded and
                            (parser.batch_pool == null or !parser.batch_pool.?.hasLeases())));
                if (parser.producer.state == .failed or permanent_binary_resource or
                    (err != error.MemoryPressure and err != error.BatchCapacityUnavailable and err != error.ResourceLimitExceeded and
                        (parser.storage.header.encoding == .ascii or parser.binary_diagnostic != null))) parser.state = .failed;
                return err;
            } orelse break;
            for (&parser.pending_tasks) |*item| {
                if (item.* == null) {
                    item.* = pending;
                    parser.execution_stats.max_inflight = @max(parser.execution_stats.max_inflight, parser.pendingCount());
                    break;
                }
            }
        }
        if (parser.pendingCount() != 0) {
            if (!parser.options.preserve_order) {
                const completed = parser.completions.?.queue.getOne(parser.io) catch {
                    parser.cancelPending();
                    parser.state = .failed;
                    return error.InvalidProducerState;
                };
                for (parser.pending_tasks, 0..) |item, i| {
                    if (item) |p| {
                        if (p.task_lease.id == completed.slot_id and p.task_lease.generation == completed.generation and p.sequence == completed.sequence) {
                            return try parser.finishTask(i);
                        }
                    }
                }
                parser.cancelPending();
                parser.state = .failed;
                return error.InvalidProducerState;
            }
            var chosen: ?usize = null;
            for (parser.pending_tasks, 0..) |item, i| {
                if (item) |p| {
                    if (chosen == null or p.sequence < parser.pending_tasks[chosen.?].?.sequence) chosen = i;
                }
            }
            return try parser.finishTask(chosen.?);
        }
        if (parser.deferred_error) |err| {
            parser.deferred_error = null;
            parser.state = .failed;
            return err;
        }
        if (parser.input_complete) {
            parser.state = .completed;
            return null;
        }
        return error.InvalidProducerState;
    }

    /// Internal streaming pipeline (Task 4.11): plans the next chunk,
    /// grows the raw buffer if needed, reads the exact bytes, and
    /// returns the chunk descriptor. Not part of the public API — Phase
    /// 5's `next` will sit on top of this; raw chunks are never
    /// presented as decoded batches.
    ///
    /// * `null` means every declared record was successfully consumed
    ///   (parser `.completed`); trailing data after the declared body is
    ///   left unread.
    /// * The returned chunk borrows the parser's raw buffer: it is valid
    ///   only until the next `nextRawChunk` call or `deinit`.
    /// * The raw buffer is allocated lazily here — metadata-only
    ///   callers never allocate it.
    /// * On any streaming failure the producer and parser enter their
    ///   `failed` states; subsequent calls report `InvalidProducerState`
    ///   instead of silently restarting.
    fn nextRawChunk(parser: *Parser) RawChunkError!?input.RawChunk {
        switch (parser.state) {
            .ready, .reading => {},
            .completed => return null,
            else => return error.InvalidProducerState,
        }
        parser.memory_control.wrapper.clearFailure();

        const plan = (parser.producer.planNext(
            &parser.storage.header,
            parser.storage.layouts,
            parser.options,
        ) catch |err| {
            // Mirror terminal producer failures (unsupported encoding,
            // unsupported variable-length elements) onto the parser;
            // retryable planning errors (e.g. RecordTooLarge) leave the
            // state untouched.
            if (parser.producer.state == .failed) parser.state = .failed;
            return err;
        }) orelse {
            parser.state = .completed;
            return null;
        };

        // Resource admission: the chunk must fit the parser's memory
        // budget (chunk_size already validates against it; oversized
        // single-record chunks can exceed chunk_size, so they are
        // checked here against the budget). The global multi-resource
        // budget lands in Phase 6.
        const byte_count = std.math.cast(usize, plan.byte_count) orelse
            return error.SizeOverflow;
        if (byte_count > parser.options.memory_budget) {
            return error.ResourceLimitExceeded;
        }

        parser.raw_buffer.ensureCapacity(byte_count) catch |err| {
            if (parser.memory_control.wrapper.budgetDenied()) return error.ResourceLimitExceeded;
            return err;
        };

        const element_count = parser.storage.header.elements[plan.element_index].count;
        const chunk = parser.producer.readPlanned(
            parser.reader,
            plan,
            parser.raw_buffer.writable()[0..byte_count],
            element_count,
        ) catch |err| {
            // TruncatedBody/ReadFailed already failed the producer; mirror
            // that onto the parser so subsequent calls report the terminal
            // state instead of restarting.
            if (parser.producer.state == .failed) parser.state = .failed;
            return err;
        };
        parser.raw_buffer.setLength(byte_count);

        // Mirror the producer's terminal states onto the parser.
        parser.state = switch (parser.producer.state) {
            .reading => .reading,
            .completed => .completed,
            else => .failed,
        };
        return chunk;
    }

    /// Releases all parser-owned resources.
    ///
    /// * Never reads from the reader (invariant 6); the caller's reader and
    ///   source are untouched.
    /// * Releases the raw input allocation (lazily allocated by the
    ///   streaming pipeline), the header metadata arena (all names,
    ///   comments, `obj_info` payloads, element/property slices), and the
    ///   compiled layouts.
    pub fn deinit(parser: *Parser) void {
        parser.cancelPending();
        if (parser.completions) |c| {
            // The worker may already have closed this queue to report a
            // terminal notification error. All workers were joined above.
            if (!c.failed.load(.acquire)) c.queue.close(parser.io);
            parser.allocator.destroy(c);
        }
        if (parser.raw_pool) |pool| {
            pool.deinit();
            parser.allocator.destroy(pool);
        }
        if (parser.task_registry) |registry| {
            registry.deinit();
            parser.allocator.destroy(registry);
        }
        if (parser.batch_pool) |pool| pool.destroy();
        parser.raw_buffer.deinit();
        parser.ascii_stage.deinit(parser.allocator);
        parser.binary_stage.deinit(parser.allocator);
        parser.ascii_reader.deinit(parser.allocator);
        parser.storage.deinit();
        parser.memory_control.destroy();
        parser.state = .destroyed;
    }
};

/// Internal test/benchmark bridge. Not re-exported by the public module.
pub fn nextRawChunkForTesting(parser: *Parser) Parser.RawChunkError!?input.RawChunk {
    return parser.nextRawChunk();
}
