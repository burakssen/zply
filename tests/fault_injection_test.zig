//! Deterministic Phase 7 fault-injection tests: the hooks block workers on
//! atomic gates, so assertions never depend on scheduling luck or sleeps.
const std = @import("std");
const internal = @import("zply_internals");

const Parser = internal.parser.Parser;
const Hooks = internal.fault_injection.Hooks;
const DecodeTask = internal.execution.DecodeTask;

// 5,462 XYZ f32 records occupy 65,544 bytes, just above the parser's native
// concurrency threshold. Exact multiples produce one task per chunk.
const records_per_chunk: usize = 5_462;
const chunk_bytes: usize = records_per_chunk * 12;

fn xyzFixture(a: std.mem.Allocator, chunk_count: usize) ![]u8 {
    const n = chunk_count * records_per_chunk;
    const header = try a.print(
        "ply\nformat binary_little_endian 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty float y\nproperty float z\nend_header\n",
        .{n},
    );
    defer a.free(header);
    const bytes = try a.alloc(u8, header.len + n * 12);
    @memcpy(bytes[0..header.len], header);
    for (0..n) |i| {
        const start = header.len + i * 12;
        const x: f32 = @floatFromInt(i);
        std.mem.writeInt(u32, bytes[start..][0..4], @bitCast(x), .little);
        @memset(bytes[start + 4 ..][0 .. 12 - 4], 0);
    }
    return bytes;
}

const Reverse = struct {
    // The worker for sequence 3 posts first, then 2, 1, 0. Unlocking the
    // next worker *after* posting forces actual queue insertion order.
    turn: std.atomic.Value(i32) = .init(3),
    rejected: std.atomic.Value(bool) = .init(false),
    recorded: std.atomic.Value(usize) = .init(0),
    notifications: [4]u64 = @splat(std.math.maxInt(u64)),

    fn before(ctx: *anyopaque, sequence: u64) void {
        const self: *Reverse = @ptrCast(@alignCast(ctx));
        const required: i32 = @intCast(sequence);
        while (!self.rejected.load(.acquire) and self.turn.load(.acquire) != required) std.atomic.spinLoopHint();
    }

    fn after(ctx: *anyopaque, sequence: u64) void {
        const self: *Reverse = @ptrCast(@alignCast(ctx));
        const index = self.recorded.fetchAdd(1, .acq_rel);
        self.notifications[index] = sequence;
        self.turn.store(@as(i32, @intCast(sequence)) - 1, .release);
    }

    fn rejectedSubmission(ctx: *anyopaque, _: u64) void {
        const self: *Reverse = @ptrCast(@alignCast(ctx));
        self.rejected.store(true, .release);
    }
};

fn checkReverseCompletion(preserve_order: bool) !void {
    const bytes = try xyzFixture(std.testing.allocator, 4);
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var control = Reverse{};
    const hooks: Hooks = .{
        .context = &control,
        .before_notify = Reverse.before,
        .after_notify = Reverse.after,
        .submission_rejected = Reverse.rejectedSubmission,
    };
    var parser = try Parser.init(std.testing.allocator, io_impl.io(), &reader, .{
        .chunk_size = chunk_bytes,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = preserve_order,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;

    const wanted: [4]u64 = if (preserve_order) .{ 0, 1, 2, 3 } else .{ 3, 2, 1, 0 };
    for (wanted) |sequence| {
        var batch = (try parser.next()).?;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(sequence, info.sequence);
        try std.testing.expectEqual(@as(u64, sequence * @as(u64, records_per_chunk)), info.first_record);
        try std.testing.expectEqual(records_per_chunk, info.record_count);
        const x = try batch.typedColumn(f32, 0);
        try std.testing.expectEqual(@as(f32, @floatFromInt(info.first_record)), x[0]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(info.first_record + @as(u64, records_per_chunk) - 1)), x[x.len - 1]);
    }
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expect(!control.rejected.load(.acquire));
    try std.testing.expectEqual(@as(u64, 4), parser.executionStats().native_submissions);
    try std.testing.expectEqual(@as(usize, 4), control.recorded.load(.acquire));
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1, 0 }, &control.notifications);
    try std.testing.expectEqual(@as(usize, 0), parser.task_registry.?.activeCount());
}

test "four tasks notify in forced reverse order but ordered Parser.next returns 0..3" {
    try checkReverseCompletion(true);
}

test "unordered Parser.next delivers forced reverse completion order" {
    try checkReverseCompletion(false);
}

const PauseAtCheckpoint = struct {
    reached: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn checkpoint(ctx: *anyopaque, sequence: u64, decoded_records: usize) void {
        const self: *PauseAtCheckpoint = @ptrCast(@alignCast(ctx));
        std.debug.assert(sequence == 0 and decoded_records == 4096);
        self.reached.store(true, .release);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
    }
};

test "cancellation during active decoding drops partial output and joins future" {
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 16384\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    var reader: std.Io.Reader = .fixed(header);
    var storage = try internal.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    const layout = &storage.layouts[0];
    const bytes = try std.testing.allocator.alloc(u8, 16384 * 12);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    var pool = try internal.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    const slot = try pool.acquire(layout, 16384);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(4) });
    defer io_impl.deinit();
    var control = PauseAtCheckpoint{};
    const hooks: Hooks = .{ .context = &control, .checkpoint = PauseAtCheckpoint.checkpoint };
    var task: DecodeTask = .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 16384,
        .input = bytes,
        .layout = layout,
        .endian = .little,
        .pool = pool,
        .slot_id = slot,
        .target = pool.target(slot),
        .test_hooks = &hooks,
    };
    try task.submit(io_impl.io());
    while (!control.reached.load(.acquire)) std.atomic.spinLoopHint();
    // The worker has written at least 4,096 records, but the batch must not
    // become ready or leased. Resume at its next cancellation checkpoint.
    task.cancel_requested.store(true, .release);
    control.release.store(true, .release);
    try std.testing.expectError(error.Cancelled, task.cancelFuture(io_impl.io()));
    try std.testing.expectEqual(internal.execution.task.State.cancelled, task.state);
    try std.testing.expect(task.future == null);
    pool.cancel(slot);
    // Reuse after the future has joined must be safe, even with partial writes.
    const reused = try pool.acquire(layout, 1);
    pool.cancel(reused);
}

const AdmissionFailure = struct {
    release_workers: std.atomic.Value(bool) = .init(false),
    blocked_workers: std.atomic.Value(usize) = .init(0),
    observed: std.atomic.Value(bool) = .init(false),

    fn before(ctx: *anyopaque, sequence: u64) void {
        const self: *AdmissionFailure = @ptrCast(@alignCast(ctx));
        if (sequence == 0) return;
        _ = self.blocked_workers.fetchAdd(1, .acq_rel);
        while (!self.release_workers.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn rejectedSubmission(ctx: *anyopaque, _: u64) void {
        const self: *AdmissionFailure = @ptrCast(@alignCast(ctx));
        self.release_workers.store(true, .release);
    }

    fn fail(ctx: *anyopaque, err: anyerror) void {
        const self: *AdmissionFailure = @ptrCast(@alignCast(ctx));
        if (err == error.OutOfMemory) self.observed.store(true, .release);
        self.release_workers.store(true, .release);
    }
};

test "real allocation failure with running futures preserves prefix and cleans reservations" {
    const n = records_per_chunk * 8;
    const header = try std.testing.allocator.print(
        "ply\nformat binary_little_endian 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty float y\nproperty float z\n" ++
            "element marker 2\nproperty double x\nproperty double y\n" ++
            "property double z\nproperty double t\nend_header\n",
        .{n},
    );
    defer std.testing.allocator.free(header);
    const bytes = try std.testing.allocator.alloc(u8, header.len + n * 12 + 2 * 32);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);
    @memset(bytes[header.len..], 0);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var control = AdmissionFailure{};
    const hooks: Hooks = .{
        .context = &control,
        .before_notify = AdmissionFailure.before,
        .admission_failure = AdmissionFailure.fail,
        .submission_rejected = AdmissionFailure.rejectedSubmission,
    };
    {
        var parser = try Parser.init(backing.allocator(), io_impl.io(), &reader, .{
            .chunk_size = chunk_bytes,
            .memory_budget = 8 * 1024 * 1024,
        });
        defer parser.deinit();
        parser.test_hooks = &hooks;

        var first = (try parser.next()).?;
        try std.testing.expectEqual(@as(u64, 0), first.info().sequence);
        first.release();
        try std.testing.expectEqual(@as(u64, 8), parser.executionStats().native_submissions);
        try std.testing.expectEqual(@as(usize, 7), parser.task_registry.?.activeCount());
        while (control.blocked_workers.load(.acquire) == 0) std.atomic.spinLoopHint();
        // At least one native future is still executing, deliberately held
        // after decoding, when the next real allocator request fails.
        // This is a *real* underlying allocator failure, not a fabricated
        // parser error. The next element requires fresh column allocations.
        backing.fail_index = backing.alloc_index;
        for (1..8) |sequence| {
            var batch = (try parser.next()).?;
            defer batch.release();
            try std.testing.expectEqual(@as(u64, @intCast(sequence)), batch.info().sequence);
        }
        try std.testing.expect(control.observed.load(.acquire));
        try std.testing.expectError(error.OutOfMemory, parser.next());
        try std.testing.expectEqual(Parser.State.failed, parser.state);
        try std.testing.expectEqual(@as(usize, 0), parser.task_registry.?.activeCount());
        try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
    }
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

const BrokenCompletion = struct {
    attempts: std.atomic.Value(usize) = .init(0),

    fn fail(ctx: *anyopaque, _: u64) bool {
        const self: *BrokenCompletion = @ptrCast(@alignCast(ctx));
        _ = self.attempts.fetchAdd(1, .acq_rel);
        return true;
    }
};

test "completion notification failure wakes unordered next and joins outstanding work" {
    const bytes = try xyzFixture(std.testing.allocator, 4);
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var control = BrokenCompletion{};
    const hooks: Hooks = .{
        .context = &control,
        .fail_notification = BrokenCompletion.fail,
    };
    var parser = try Parser.init(std.testing.allocator, io_impl.io(), &reader, .{
        .chunk_size = chunk_bytes,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = false,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;

    try std.testing.expectError(error.InvalidProducerState, parser.next());
    try std.testing.expectEqual(Parser.State.failed, parser.state);
    try std.testing.expect(control.attempts.load(.acquire) > 0);
    try std.testing.expect(parser.completions.?.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), parser.task_registry.?.activeCount());
    try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
    try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().leased_bytes);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

// A bounded completion queue must not accumulate events in ordered mode.
// Ordered delivery awaits each future directly; publishing unused events
// could eventually make worker notification block when the queue fills.
test "ordered Phase 9 ASCII futures never publish unused queue notifications" {
    const a = std.testing.allocator;
    const count: usize = 200_000;
    const row = "1 2 3\n";
    const header = try a.print(
        "ply\nformat ascii 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty int id\nproperty double y\nend_header\n",
        .{count},
    );
    defer a.free(header);
    const bytes = try a.alloc(u8, header.len + count * row.len);
    defer a.free(bytes);
    @memcpy(bytes[0..header.len], header);
    for (0..count) |i| {
        @memcpy(bytes[header.len + i * row.len ..][0..row.len], row);
    }

    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var control = BrokenCompletion{};
    const hooks: Hooks = .{
        .context = &control,
        .fail_notification = BrokenCompletion.fail,
    };
    var parser = try Parser.init(a, io_impl.io(), &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = true,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;

    var delivered: usize = 0;
    var sequence: u64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(sequence, info.sequence);
        try std.testing.expectEqual(@as(u64, @intCast(delivered)), info.first_record);
        const xs = try batch.typedColumn(f32, 0);
        const ids = try batch.typedColumn(i32, 1);
        const ys = try batch.typedColumn(f64, 2);
        try std.testing.expectEqual(info.record_count, xs.len);
        for (xs, ids, ys) |x, id, y| {
            try std.testing.expectEqual(@as(f32, 1), x);
            try std.testing.expectEqual(@as(i32, 2), id);
            try std.testing.expectEqual(@as(f64, 3), y);
        }
        delivered += info.record_count;
        sequence += 1;
    }
    try std.testing.expectEqual(count, delivered);
    try std.testing.expect(sequence > 8);
    try std.testing.expect(parser.executionStats().native_submissions > 0);
    // Fail-injection must never even run: ordered tasks do not use the queue.
    try std.testing.expectEqual(@as(usize, 0), control.attempts.load(.acquire));
}

// The same queue-routing invariant is shared with the Phase 7 binary path.
test "ordered binary futures also avoid the unordered completion queue" {
    const a = std.testing.allocator;
    const chunks: usize = 12;
    const bytes = try xyzFixture(a, chunks);
    defer a.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var control = BrokenCompletion{};
    const hooks: Hooks = .{
        .context = &control,
        .fail_notification = BrokenCompletion.fail,
    };
    var parser = try Parser.init(a, io_impl.io(), &reader, .{
        .chunk_size = chunk_bytes,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = true,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;

    var count: usize = 0;
    var sequence: u64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        try std.testing.expectEqual(sequence, batch.info().sequence);
        try std.testing.expectEqual(@as(u64, @intCast(count)), batch.info().first_record);
        count += batch.info().record_count;
        sequence += 1;
    }
    try std.testing.expectEqual(chunks * records_per_chunk, count);
    try std.testing.expectEqual(@as(u64, chunks), sequence);
    try std.testing.expectEqual(@as(usize, 0), control.attempts.load(.acquire));
}

const PauseInsideAsciiList = struct {
    reached: std.atomic.Value(bool) = .init(false),
    resume_decoding: std.atomic.Value(bool) = .init(false),

    fn checkpoint(ctx: *anyopaque, sequence: u64, decoded_items: usize) void {
        const self: *PauseInsideAsciiList = @ptrCast(@alignCast(ctx));
        std.debug.assert(sequence == 0 and decoded_items == 4096);
        self.reached.store(true, .release);
        while (!self.resume_decoding.load(.acquire)) std.atomic.spinLoopHint();
    }
};

test "Phase 9 cancellation during a large ASCII list joins the future without publishing" {
    const a = std.testing.allocator;
    const count: usize = 10_000;
    const header = "ply\nformat ascii 1.0\nelement face 1\n" ++
        "property list ushort int indices\nend_header\n";
    var header_reader: std.Io.Reader = .fixed(header);
    var storage = try internal.header_parser.parseHeader(a, &header_reader, .{});
    defer storage.deinit();
    const layout = &storage.layouts[0];
    const properties = storage.header.elements[0].properties;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    try line.appendSlice(a, "10000");
    var numeric: [32]u8 = undefined;
    for (0..count) |i| {
        try line.appendSlice(a, try std.fmt.bufPrint(&numeric, " {d}", .{i}));
    }
    try line.append(a, '\n');
    const boundaries = [_]usize{ 0, line.items.len };
    const totals = [_]usize{count};
    const pool = try internal.batch_storage.Pool.create(a);
    defer pool.destroy();
    const slot = try pool.acquireAsciiSized(layout, properties, 1, &totals);
    var io_impl: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(4) });
    defer io_impl.deinit();
    var control = PauseInsideAsciiList{};
    const hooks: Hooks = .{
        .context = &control,
        .list_item_checkpoint = PauseInsideAsciiList.checkpoint,
    };
    var task: DecodeTask = .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 1,
        .input = line.items,
        .layout = layout,
        .endian = .little,
        .encoding = .ascii,
        .ascii_boundaries = &boundaries,
        .ascii_properties = properties,
        .ascii_token_limit = 64,
        .ascii_item_limit = count,
        .pool = pool,
        .slot_id = slot,
        .target = pool.target(slot),
        .test_hooks = &hooks,
    };
    try task.submit(io_impl.io());
    // The cancellation request is made while the worker is provably inside
    // this list, after completing 4,096 items but before the next check.
    while (!control.reached.load(.acquire)) std.atomic.spinLoopHint();
    task.cancel_requested.store(true, .release);
    control.resume_decoding.store(true, .release);
    try std.testing.expectError(error.Cancelled, task.cancelFuture(io_impl.io()));
    try std.testing.expectEqual(internal.execution.task.State.cancelled, task.state);
    try std.testing.expect(task.future == null);
    pool.cancel(slot);
    const reused = try pool.acquireAsciiSized(layout, properties, 1, &totals);
    pool.cancel(reused);
}

// A valid published prefix must remain leased even if a later native ASCII
// worker detects a malformed number while other tasks are in flight.
test "Phase 9 ordered invalid later ASCII chunk preserves earlier leased batch" {
    const a = std.testing.allocator;
    const count: usize = 40_000;
    const bad_at: usize = 25_000;
    const header = try a.print(
        "ply\nformat ascii 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty int id\nproperty double y\nend_header\n",
        .{count},
    );
    defer a.free(header);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, header);
    var record_start: u64 = 0;
    var token_start: u64 = 0;
    var line: [64]u8 = undefined;
    for (0..count) |i| {
        if (i == bad_at) {
            record_start = @intCast(bytes.items.len);
            token_start = record_start + 2;
            try bytes.appendSlice(a, "1 invalid 3\n");
        } else {
            try bytes.appendSlice(a, try std.fmt.bufPrint(&line, "1 {d} 3\n", .{i}));
        }
    }
    var reader: std.Io.Reader = .fixed(bytes.items);
    var io_impl: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var parser = try Parser.init(a, io_impl.io(), &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = true,
    });
    defer parser.deinit();

    var retained = (try parser.next()).?;
    defer retained.release();
    try std.testing.expectEqual(@as(u64, 0), retained.info().first_record);
    try std.testing.expect(retained.info().record_count > 0);
    var delivered: usize = retained.info().record_count;
    while (true) {
        const value = parser.next() catch |err| {
            try std.testing.expectEqual(error.InvalidNumber, err);
            break;
        } orelse return error.MissingExpectedFailure;
        var batch = value;
        defer batch.release();
        try std.testing.expectEqual(@as(u64, @intCast(delivered)), batch.info().first_record);
        delivered += batch.info().record_count;
    }
    try std.testing.expect(delivered > 0 and delivered <= bad_at);
    const diagnostic = parser.asciiDiagnostic().?;
    try std.testing.expectEqual(@as(u64, bad_at), diagnostic.record_index.?);
    try std.testing.expectEqual(@as(u64, 1), diagnostic.property_index.?);
    try std.testing.expectEqual(record_start, diagnostic.byte_offset.?);
    try std.testing.expectEqual(token_start, diagnostic.token_byte_offset.?);
    try std.testing.expect(retained.isValid());
    const first_x = try retained.typedColumn(f32, 0);
    const first_id = try retained.typedColumn(i32, 1);
    try std.testing.expectEqual(@as(f32, 1), first_x[0]);
    try std.testing.expectEqual(@as(i32, 0), first_id[0]);
    try std.testing.expectEqual(@as(usize, 0), parser.task_registry.?.activeCount());
    try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

// Exercise the shared completion-notification failure path with ASCII work,
// not only the Phase 7 binary tasks. A failed notification must wake the
// unordered consumer and join every submitted future before returning.
test "Phase 9 unordered ASCII notification failure closes the queue and joins tasks" {
    const a = std.testing.allocator;
    const count: usize = 40_000;
    const header = try a.print(
        "ply\nformat ascii 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty int id\nproperty double y\nend_header\n",
        .{count},
    );
    defer a.free(header);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, header);
    for (0..count) |_| try bytes.appendSlice(a, "1 2 3\n");
    var reader: std.Io.Reader = .fixed(bytes.items);
    var io_impl: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var control = BrokenCompletion{};
    const hooks: Hooks = .{
        .context = &control,
        .fail_notification = BrokenCompletion.fail,
    };
    var parser = try Parser.init(a, io_impl.io(), &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = false,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;

    try std.testing.expectError(error.InvalidProducerState, parser.next());
    try std.testing.expectEqual(Parser.State.failed, parser.state);
    try std.testing.expect(control.attempts.load(.acquire) > 0);
    try std.testing.expect(parser.completions.?.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), parser.task_registry.?.activeCount());
    try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
    try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().leased_bytes);
}

// Target actual allocator failures at each individually named Phase 9
// admission allocation stage. This complements, rather than replaces, the
// broad fail-index sweep: stage names prevent an early allocation from
// obscuring later output/metadata cleanup paths.
const AsciiStageFailure = struct {
    failing: *std.testing.FailingAllocator,
    target: internal.fault_injection.AsciiAdmissionPoint,
    armed: bool = false,

    fn onStage(ctx: *anyopaque, point: internal.fault_injection.AsciiAdmissionPoint) void {
        const self: *AsciiStageFailure = @ptrCast(@alignCast(ctx));
        if (!self.armed and self.target == point) {
            self.failing.fail_index = self.failing.alloc_index;
            self.armed = true;
        }
    }
};

test "Phase 9 actual allocation failures clean up at each ASCII admission stage" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, "ply\nformat ascii 1.0\nelement face 300\n" ++
        "property uint id\nproperty list uchar int indices\nend_header\n");
    var line: [48]u8 = undefined;
    for (0..300) |i| {
        try bytes.appendSlice(a, try std.fmt.bufPrint(&line, "{d} 2 1 2\n", .{i}));
    }

    const points = [_]internal.fault_injection.AsciiAdmissionPoint{
        .output_pool_create,
        .task_registry_create,
        .completion_state_create,
        .record_scratch,
        .stage_raw_growth,
        .stage_boundary_growth,
        .preflight_totals,
        .raw_copy,
        .boundary_copy,
        .output_storage,
    };
    for (points) |point| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var controller: AsciiStageFailure = .{ .failing = &failing, .target = point };
        const hooks: Hooks = .{
            .context = &controller,
            .ascii_admission_point = AsciiStageFailure.onStage,
        };
        var reader: std.Io.Reader = .fixed(bytes.items);
        // Completion metadata is allocated only for unordered delivery.
        const ordered = point != .completion_state_create;
        {
            var parser = try Parser.init(failing.allocator(), std.testing.io, &reader, .{
                .chunk_size = 128 * 1024,
                .memory_budget = 8 * 1024 * 1024,
                .preserve_order = ordered,
            });
            defer parser.deinit();
            parser.test_hooks = &hooks;

            // If a checkpoint unexpectedly does not fail, release any
            // returned lease before reporting the assertion failure.
            if (parser.next()) |maybe_batch| {
                if (maybe_batch) |value| {
                    var batch = value;
                    batch.release();
                }
                return error.ExpectedInjectedOutOfMemory;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
            }
            try std.testing.expect(controller.armed);
            try std.testing.expectEqual(Parser.State.failed, parser.state);
            if (parser.task_registry) |registry| {
                try std.testing.expectEqual(@as(usize, 0), registry.activeCount());
            }
            const memory = parser.memoryStats();
            try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
            try std.testing.expectEqual(@as(usize, 0), memory.leased_bytes);
            try std.testing.expect(memory.peak_total_bytes <= memory.budget_bytes);
        }
        // No outstanding decoded storage, task descriptors, staged lines,
        // reservations, or parser metadata may survive destruction.
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
