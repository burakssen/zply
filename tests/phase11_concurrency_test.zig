//! M13: deterministic native std.Io completion ordering, error precedence,
//! read-ahead failure draining and cooperative cancellation.
//!
//! The fixed atomics below force completion order. They are not timing-based
//! stress tests and never rely on arbitrary sleeps or worker scheduling luck.
const std = @import("std");
const internal = @import("zply_internals");
const Parser = internal.parser.Parser;
const Hooks = internal.fault_injection.Hooks;

// 5462 * 12 = 65544 bytes: above the native submit threshold (64 KiB).
const records_per_chunk: usize = 5462;
const chunk_size: usize = records_per_chunk * 12;
const chunk_count: usize = 4;

fn makeXyz(count: usize, declared: usize) ![]u8 {
    const header = try std.testing.allocator.print(
        "ply\nformat binary_little_endian 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty float y\nproperty float z\nend_header\n",
        .{declared},
    );
    defer std.testing.allocator.free(header);
    const bytes = try std.testing.allocator.alloc(u8, header.len + count * 12);
    @memcpy(bytes[0..header.len], header);
    for (0..count) |i| {
        const start = header.len + i * 12;
        std.mem.writeInt(u32, bytes[start..][0..4], @bitCast(@as(f32, @floatFromInt(i))), .little);
        std.mem.writeInt(u32, bytes[start + 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(i * 2))), .little);
        std.mem.writeInt(u32, bytes[start + 8 ..][0..4], @bitCast(@as(f32, @floatFromInt(i * 3))), .little);
    }
    return bytes;
}

const OrderGate = struct {
    desired: [chunk_count]u64,
    next: std.atomic.Value(usize) = .init(0),
    rejected: std.atomic.Value(bool) = .init(false),
    observed: [chunk_count]u64 = @splat(std.math.maxInt(u64)),
    fail_a: ?u64 = null,
    fail_b: ?u64 = null,

    fn before(ctx: *anyopaque, sequence: u64) void {
        const self: *OrderGate = @ptrCast(@alignCast(ctx));
        while (!self.rejected.load(.acquire)) {
            const index = self.next.load(.acquire);
            if (index < chunk_count and self.desired[index] == sequence) return;
            std.atomic.spinLoopHint();
        }
    }

    fn after(ctx: *anyopaque, sequence: u64) void {
        const self: *OrderGate = @ptrCast(@alignCast(ctx));
        if (self.rejected.load(.acquire)) return;
        // Only the desired worker can enter here; publish its observation
        // before waking the next worker.
        const index = self.next.load(.acquire);
        std.debug.assert(index < chunk_count and self.desired[index] == sequence);
        self.observed[index] = sequence;
        self.next.store(index + 1, .release);
    }

    fn failedDecode(ctx: *anyopaque, sequence: u64) ?anyerror {
        const self: *OrderGate = @ptrCast(@alignCast(ctx));
        if (self.fail_a != null and self.fail_a.? == sequence) return error.InvalidLayout;
        if (self.fail_b != null and self.fail_b.? == sequence) return error.InvalidColumnType;
        return null;
    }

    fn rejectedSubmission(ctx: *anyopaque, _: u64) void {
        const self: *OrderGate = @ptrCast(@alignCast(ctx));
        self.rejected.store(true, .release);
    }
};

fn verifyBatch(batch: *internal.batch_storage.Batch, sequence: u64) !void {
    const info = batch.info();
    try std.testing.expectEqual(sequence, info.sequence);
    try std.testing.expectEqual(@as(u64, records_per_chunk) * sequence, info.first_record);
    try std.testing.expectEqual(records_per_chunk, info.record_count);
    const x = try batch.typedColumn(f32, 0);
    const y = try batch.typedColumn(f32, 1);
    const z = try batch.typedColumn(f32, 2);
    for (x, y, z, 0..) |vx, vy, vz, j| {
        const i = @as(usize, @intCast(info.first_record)) + j;
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), vx);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 2)), vy);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 3)), vz);
    }
}

fn assertClean(parser: *Parser) !void {
    try std.testing.expectEqual(@as(usize, 0), parser.task_registry.?.activeCount());
    const mem = parser.memoryStats();
    try std.testing.expectEqual(@as(usize, 0), mem.reserved_bytes);
    try std.testing.expectEqual(@as(usize, 0), mem.leased_bytes);
    try std.testing.expect(mem.live_bytes <= mem.budget_bytes);
    try std.testing.expect(mem.peak_total_bytes <= mem.budget_bytes);
}

fn exerciseOrder(order: [chunk_count]u64, ordered: bool, fail_a: ?u64, fail_b: ?u64) !void {
    const bytes = try makeXyz(chunk_count * records_per_chunk, chunk_count * records_per_chunk);
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var gate: OrderGate = .{ .desired = order, .fail_a = fail_a, .fail_b = fail_b };
    const hooks: Hooks = .{
        .context = &gate,
        .before_notify = OrderGate.before,
        .after_notify = OrderGate.after,
        .decode_failure = OrderGate.failedDecode,
        .submission_rejected = OrderGate.rejectedSubmission,
    };
    var parser = try Parser.init(std.testing.allocator, io_impl.io(), &reader, .{
        .chunk_size = chunk_size,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = ordered,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;

    var earliest_failure = fail_a;
    if (fail_b) |b| earliest_failure = if (earliest_failure) |a| @min(a, b) else b;
    var delivered: usize = 0;
    if (ordered) {
        for (0..chunk_count) |index| {
            if (earliest_failure != null and index == @as(usize, @intCast(earliest_failure.?))) break;
            var batch = (try parser.next()).?;
            try verifyBatch(&batch, @intCast(index));
            batch.release();
            delivered += 1;
        }
    } else if (earliest_failure == null) {
        for (order) |sequence| {
            var batch = (try parser.next()).?;
            try verifyBatch(&batch, sequence);
            batch.release();
            delivered += 1;
        }
    }

    if (earliest_failure) |first| {
        const reported_sequence = if (ordered) first else order[0];
        const expected: anyerror = if (fail_a != null and reported_sequence == fail_a.?)
            error.InvalidLayout
        else
            error.InvalidColumnType;
        try std.testing.expectError(expected, parser.next());
        try std.testing.expectEqual(Parser.State.failed, parser.state);
        try std.testing.expectError(error.InvalidProducerState, parser.next());
        if (ordered) try std.testing.expectEqual(@as(usize, @intCast(first)), delivered);
    } else {
        try std.testing.expect((try parser.next()) == null);
        try std.testing.expectEqual(Parser.State.completed, parser.state);
        try std.testing.expectEqual(chunk_count, delivered);
    }
    try std.testing.expect(!gate.rejected.load(.acquire));
    try std.testing.expectEqual(@as(u64, chunk_count), parser.executionStats().native_submissions);
    try std.testing.expectEqual(chunk_count, gate.next.load(.acquire));
    try std.testing.expectEqualSlices(u64, &order, &gate.observed);
    try assertClean(&parser);
}

test "M13 permutations force distinct completion order but preserve ordered and unordered records" {
    const orders = [_][chunk_count]u64{
        .{ 0, 1, 2, 3 }, .{ 3, 2, 1, 0 },
        .{ 2, 0, 3, 1 }, .{ 1, 3, 0, 2 },
    };
    for (orders) |order| {
        try exerciseOrder(order, true, null, null);
        try exerciseOrder(order, false, null, null);
    }
}

test "M13 ordered failures report earliest logical task regardless of completion order" {
    // The later failing worker (sequence 3) actually finishes first.
    try exerciseOrder(.{ 3, 2, 1, 0 }, true, 2, 3);
    // Earliest task, middle task and final task fail in separate sessions.
    try exerciseOrder(.{ 3, 2, 1, 0 }, true, 0, null);
    try exerciseOrder(.{ 3, 2, 1, 0 }, true, 1, null);
    try exerciseOrder(.{ 3, 2, 1, 0 }, true, 3, null);
}

test "M13 unordered failure from earliest completed worker joins all later work" {
    try exerciseOrder(.{ 3, 2, 1, 0 }, false, 3, null);
}

const ReadAhead = struct {
    release: std.atomic.Value(bool) = .init(false),
    waiting: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
    rejected: std.atomic.Value(bool) = .init(false),

    fn before(ctx: *anyopaque, _: u64) void {
        const self: *ReadAhead = @ptrCast(@alignCast(ctx));
        _ = self.waiting.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
    }
    fn admissionFailed(ctx: *anyopaque, err: anyerror) void {
        const self: *ReadAhead = @ptrCast(@alignCast(ctx));
        if (err == error.TruncatedBody) _ = self.failures.fetchAdd(1, .acq_rel);
        self.release.store(true, .release);
    }
    fn submissionRejected(ctx: *anyopaque, _: u64) void {
        const self: *ReadAhead = @ptrCast(@alignCast(ctx));
        self.rejected.store(true, .release);
        self.release.store(true, .release);
    }
};

test "M13 read-ahead truncation drains admitted native tasks before terminal error" {
    const bytes = try makeXyz(chunk_count * records_per_chunk, chunk_count * records_per_chunk + 1);
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var gate = ReadAhead{};
    const hooks: Hooks = .{
        .context = &gate,
        .before_notify = ReadAhead.before,
        .admission_failure = ReadAhead.admissionFailed,
        .submission_rejected = ReadAhead.submissionRejected,
    };
    var parser = try Parser.init(std.testing.allocator, io_impl.io(), &reader, .{
        .chunk_size = chunk_size,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = true,
    });
    defer parser.deinit();
    parser.test_hooks = &hooks;
    // All four futures are admitted before the truncated fifth is read;
    // the admission callback opens the gate while they are still active.
    for (0..chunk_count) |sequence| {
        var batch = (try parser.next()).?;
        try verifyBatch(&batch, @intCast(sequence));
        batch.release();
    }
    try std.testing.expectEqual(@as(usize, 1), gate.failures.load(.acquire));
    try std.testing.expectEqual(chunk_count, gate.waiting.load(.acquire));
    try std.testing.expect(!gate.rejected.load(.acquire));
    try std.testing.expectError(error.TruncatedBody, parser.next());
    try std.testing.expectEqual(Parser.State.failed, parser.state);
    try assertClean(&parser);
}

const DecodeGate = struct {
    reached: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    fn atRecord(ctx: *anyopaque, sequence: u64, records: usize) void {
        const self: *DecodeGate = @ptrCast(@alignCast(ctx));
        if (sequence != 0 or records != 4096) return;
        self.reached.store(true, .release);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
    }
};

test "M13 cancellation while a native binary task is decoding prevents partial publication" {
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 16384\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    var reader: std.Io.Reader = .fixed(header);
    var storage = try internal.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    const data = try std.testing.allocator.alloc(u8, 16384 * 12);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    const pool = try internal.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    const slot = try pool.acquire(&storage.layouts[0], 16384);
    var control = DecodeGate{};
    const hooks: Hooks = .{ .context = &control, .checkpoint = DecodeGate.atRecord };
    var task: internal.execution.DecodeTask = .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 16384,
        .input = data,
        .layout = &storage.layouts[0],
        .endian = .little,
        .pool = pool,
        .slot_id = slot,
        .target = pool.target(slot),
        .test_hooks = &hooks,
    };
    var executor: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(4) });
    defer executor.deinit();
    try task.submit(executor.io());
    while (!control.reached.load(.acquire)) std.atomic.spinLoopHint();
    task.cancel_requested.store(true, .release);
    control.release.store(true, .release);
    try std.testing.expectError(error.Cancelled, task.cancelFuture(executor.io()));
    try std.testing.expectEqual(internal.execution.task.State.cancelled, task.state);
    try std.testing.expect(task.future == null);
    pool.cancel(slot);
    const reused = try pool.acquire(&storage.layouts[0], 1);
    pool.cancel(reused);
}

const ShutdownGate = struct {
    waiting: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    cancellation_seen: std.atomic.Value(bool) = .init(false),

    fn checkpoint(ctx: *anyopaque, sequence: u64, count: usize) void {
        const self: *ShutdownGate = @ptrCast(@alignCast(ctx));
        if (sequence == 0 or count != 4096) return;
        _ = self.waiting.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
    }
    fn afterCancel(ctx: *anyopaque) void {
        const self: *ShutdownGate = @ptrCast(@alignCast(ctx));
        self.cancellation_seen.store(true, .release);
        self.release.store(true, .release);
    }
    fn submissionRejected(ctx: *anyopaque, _: u64) void {
        const self: *ShutdownGate = @ptrCast(@alignCast(ctx));
        // Unblock test-only gates so this can fail an assertion instead of
        // hanging if an executor cannot provide the intended concurrency.
        self.release.store(true, .release);
    }
};

fn exerciseShutdown(ordered: bool) !void {
    const bytes = try makeXyz(chunk_count * records_per_chunk, chunk_count * records_per_chunk);
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(8) });
    defer io_impl.deinit();
    var control = ShutdownGate{};
    const hooks: Hooks = .{
        .context = &control,
        .checkpoint = ShutdownGate.checkpoint,
        .after_cancel_signal = ShutdownGate.afterCancel,
        .submission_rejected = ShutdownGate.submissionRejected,
    };
    var parser = try Parser.init(std.testing.allocator, io_impl.io(), &reader, .{
        .chunk_size = chunk_size,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = ordered,
    });
    parser.test_hooks = &hooks;
    var deinitialized = false;
    defer if (!deinitialized) parser.deinit();
    var first = (try parser.next()).?;
    try verifyBatch(&first, 0);
    first.release();
    try std.testing.expectEqual(@as(u64, chunk_count), parser.executionStats().native_submissions);
    while (control.waiting.load(.acquire) < chunk_count - 1 and !control.release.load(.acquire))
        std.atomic.spinLoopHint();
    try std.testing.expectEqual(chunk_count - 1, control.waiting.load(.acquire));
    try std.testing.expectEqual(@as(usize, chunk_count - 1), parser.task_registry.?.activeCount());
    // M13 cancellation seam opens the worker gates after setting all their
    // cancel flags, but before joining or freeing their backing buffers.
    parser.deinit();
    deinitialized = true;
    try std.testing.expect(control.cancellation_seen.load(.acquire));
    try std.testing.expectEqual(Parser.State.destroyed, parser.state);
    // std.testing.allocator detects any unreclaimed output/raw/task memory.
}

test "M13 parser destruction joins native tasks paused in decoding for both delivery modes" {
    try exerciseShutdown(true);
    try exerciseShutdown(false);
}

const ListGate = struct {
    reached: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    fn atItem(ctx: *anyopaque, _: u64, count: usize) void {
        const self: *ListGate = @ptrCast(@alignCast(ctx));
        if (count != 4096) return;
        self.reached.store(true, .release);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
    }
};

test "M13 native binary variable-list cancellation joins before reclaiming partial output" {
    const header = "ply\nformat binary_big_endian 1.0\nelement face 1\n" ++
        "property list uint int indices\nend_header\n";
    var reader: std.Io.Reader = .fixed(header);
    var storage = try internal.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    const layout = &storage.layouts[0];
    const props = storage.header.elements[0].properties;
    const item_count: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, 4 + item_count * 4);
    defer std.testing.allocator.free(data);
    std.mem.writeInt(u32, data[0..4], @intCast(item_count), .big);
    for (0..item_count) |i| std.mem.writeInt(u32, data[4 + i * 4 ..][0..4], @intCast(i), .big);
    const offsets = [_]usize{ 0, data.len };
    const totals = [_]usize{item_count};
    const pool = try internal.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    const slot = try pool.acquireBinaryVariableSized(layout, props, 1, &totals);
    var control = ListGate{};
    const hooks: Hooks = .{ .context = &control, .list_item_checkpoint = ListGate.atItem };
    var task: internal.execution.DecodeTask = .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 1,
        .encoding = .binary_variable,
        .input = data,
        .binary_boundaries = &offsets,
        .binary_totals = &totals,
        .layout = layout,
        .endian = .big,
        .pool = pool,
        .slot_id = slot,
        .target = pool.target(slot),
        .test_hooks = &hooks,
    };
    var executor: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(4) });
    defer executor.deinit();
    try task.submit(executor.io());
    while (!control.reached.load(.acquire)) std.atomic.spinLoopHint();
    task.cancel_requested.store(true, .release);
    control.release.store(true, .release);
    try std.testing.expectError(error.Cancelled, task.cancelFuture(executor.io()));
    try std.testing.expectEqual(internal.execution.task.State.cancelled, task.state);
    try std.testing.expect(task.future == null);
    pool.cancel(slot);
    const reused = try pool.acquireBinaryVariableSized(layout, props, 1, &totals);
    pool.cancel(reused);
}
