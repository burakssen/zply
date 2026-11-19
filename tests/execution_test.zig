//! Phase 7 foundation tests: stable task metadata, synchronous decoder
//! execution, cancellation state, and sequence ordering.
const std = @import("std");
const internals = @import("zply_internals");

test "DecodeTask synchronous baseline publishes only after completion" {
    const header_text = "ply\nformat binary_little_endian 1.0\nelement vertex 2\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    var header_reader: std.Io.Reader = .fixed(header_text);
    var storage = try internals.header_parser.parseHeader(std.testing.allocator, &header_reader, .{});
    defer storage.deinit();
    const layout = &storage.layouts[0];
    const fixed = try internals.decode.FixedLayout.initForEncoding(layout, storage.header.encoding);

    var bytes: [24]u8 = undefined;
    const values = [_][3]f32{ .{ 1, 2, 3 }, .{ 4, 5, 6 } };
    for (values, 0..) |record_values, i| {
        const record = bytes[i * 12 ..][0..12];
        for (record_values, 0..) |value, axis| {
            const bits: u32 = @bitCast(value);
            std.mem.writeInt(u32, record[axis * 4 ..][0..4], bits, .little);
        }
    }

    var pool = try internals.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    const slot = try pool.acquire(layout, 2);
    var task: internals.execution.DecodeTask = .{
        .sequence = 7,
        .element_index = 0,
        .first_record = 4,
        .record_count = 2,
        .input = &bytes,
        .layout = layout,
        .endian = fixed.endian,
        .pool = pool,
        .slot_id = slot,
    };
    try internals.execution.Scheduler.run(&task);
    try std.testing.expectEqual(internals.execution.task.State.completed, task.state);
    var batch = pool.publish(slot, .{ .element_index = 0, .first_record = 4, .record_count = 2, .sequence = 7 });
    const x = try batch.typedColumn(f32, 0);
    const z = try batch.typedColumn(f32, 2);
    try std.testing.expectEqual(@as(f32, 1), x[0]);
    try std.testing.expectEqual(@as(f32, 6), z[1]);

    batch.release();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const second_slot = try pool.acquire(layout, 2);
    const third_slot = try pool.acquire(layout, 2);
    const make_task = struct {
        fn create(pool_value: *internals.batch_storage.Pool, layout_value: *const internals.layout.ElementLayout, input: []const u8, slot_id: usize, sequence: u64) internals.execution.DecodeTask {
            return .{
                .sequence = sequence,
                .element_index = 0,
                .first_record = sequence * 2,
                .record_count = 2,
                .input = input,
                .layout = layout_value,
                .endian = .little,
                .pool = pool_value,
                .slot_id = slot_id,
            };
        }
    };
    var window = internals.execution.Window{};
    try window.submit(threaded.io(), make_task.create(pool, layout, &bytes, second_slot, 0));
    try window.submit(threaded.io(), make_task.create(pool, layout, &bytes, third_slot, 1));
    const completed0 = try window.popNext(threaded.io());
    try std.testing.expectEqual(@as(u64, 0), completed0.sequence);
    var batch0 = pool.publish(completed0.slot_id, .{ .element_index = 0, .first_record = 0, .record_count = 2, .sequence = 0 });
    batch0.release();
    const completed1 = try window.popNext(threaded.io());
    try std.testing.expectEqual(@as(u64, 1), completed1.sequence);
    var batch1 = pool.publish(completed1.slot_id, .{ .element_index = 0, .first_record = 2, .record_count = 2, .sequence = 1 });
    batch1.release();
}

test "task cancellation and sequence reorder state are deterministic" {
    var cancellation = internals.execution.Cancellation{};
    try cancellation.check();
    cancellation.request();
    try std.testing.expectError(error.Cancelled, cancellation.check());

    var reorder = internals.execution.ReorderState{};
    try std.testing.expect(reorder.accepts(0));
    try std.testing.expect(!reorder.accepts(1));
    reorder.delivered();
    try std.testing.expect(reorder.accepts(1));
}

test "scheduler submits a bounded ordered task window" {
    const header_text = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(header_text);
    var storage = try internals.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    const layout = &storage.layouts[0];
    var pool = try internals.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    var input_a: [4]u8 = .{ 0, 0, 128, 63 };
    var input_b: [4]u8 = .{ 0, 0, 0, 64 };
    const slot_a = try pool.acquire(layout, 1);
    const slot_b = try pool.acquire(layout, 1);
    const task_a: internals.execution.DecodeTask = .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 1,
        .input = &input_a,
        .layout = layout,
        .endian = .little,
        .pool = pool,
        .slot_id = slot_a,
    };
    const task_b: internals.execution.DecodeTask = .{
        .sequence = 1,
        .element_index = 0,
        .first_record = 1,
        .record_count = 1,
        .input = &input_b,
        .layout = layout,
        .endian = .little,
        .pool = pool,
        .slot_id = slot_b,
    };
    var scheduler = internals.execution.Scheduler.init(std.testing.io);
    try scheduler.submit(task_a);
    try scheduler.submit(task_b);
    try std.testing.expectEqual(@as(usize, 2), scheduler.pending());
    const first = (try scheduler.poll()).?;
    try std.testing.expectEqual(@as(u64, 0), first.sequence);
    var batch_a = pool.publish(first.slot_id, .{ .element_index = 0, .first_record = 0, .record_count = 1, .sequence = 0 });
    try std.testing.expectEqual(@as(f32, 1), (try batch_a.typedColumn(f32, 0))[0]);
    batch_a.release();
    const second = (try scheduler.poll()).?;
    try std.testing.expectEqual(@as(u64, 1), second.sequence);
    var batch_b = pool.publish(second.slot_id, .{ .element_index = 0, .first_record = 1, .record_count = 1, .sequence = 1 });
    try std.testing.expectEqual(@as(f32, 2), (try batch_b.typedColumn(f32, 0))[0]);
    batch_b.release();
    try std.testing.expect((try scheduler.poll()) == null);
}

test "batch output is ready before it becomes consumer leased" {
    const header_text = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(header_text);
    var storage = try internals.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    var pool = try internals.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    const layout = &storage.layouts[0];
    const slot = try pool.acquire(layout, 1);
    var data = [_]u8{ 0, 0, 128, 63 };
    try pool.decode(slot, layout, .little, &data, 1);
    pool.publishReady(slot, .{ .element_index = 0, .first_record = 0, .record_count = 1, .sequence = 0 });
    var batch = pool.leaseReady(slot);
    defer batch.release();
    try std.testing.expectEqual(@as(f32, 1), (try batch.typedColumn(f32, 0))[0]);
}

test "scheduler selects the lowest logical failure sequence" {
    var scheduler = internals.execution.Scheduler.init(std.testing.io);
    scheduler.recordFailure(.{ .sequence = 8, .element_index = 1, .first_record = 4, .record_count = 2, .error_value = error.InvalidLayout });
    scheduler.recordFailure(.{ .sequence = 3, .element_index = 0, .first_record = 9, .record_count = 1, .error_value = error.Cancelled });
    try std.testing.expectEqual(@as(u64, 3), scheduler.failure().?.sequence);
    try std.testing.expectEqual(@as(usize, 0), scheduler.failure().?.element_index);
}


test "cancelling an execution window releases its unpublished output slots" {
    const header_text = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(header_text);
    var storage = try internals.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    var pool = try internals.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();

    const slot = try pool.acquire(&storage.layouts[0], 1);
    const bytes = [_]u8{ 0, 0, 128, 63 };
    var window = internals.execution.Window{};
    try window.submit(std.testing.io, .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 1,
        .input = &bytes,
        .layout = &storage.layouts[0],
        .endian = .little,
        .pool = pool,
        .slot_id = slot,
    });
    window.cancelAll(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), window.pending());

    // Cancellation must return the slot to the pool; otherwise a failed
    // decode would strand a partially written output allocation forever.
    const reused = try pool.acquire(&storage.layouts[0], 1);
    try std.testing.expectEqual(slot, reused);
    pool.cancel(reused);
}
