const std = @import("std");
const internal = @import("zply_internals");

test "decode task cancellation is checked before publishing output" {
    const header_text = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(header_text);
    var storage = try internal.header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();
    const layout = &storage.layouts[0];
    var pool = try internal.batch_storage.Pool.create(std.testing.allocator);
    defer pool.destroy();
    const slot = try pool.acquire(layout, 1);
    var input = [_]u8{ 0, 0, 128, 63 };
    var task: internal.execution.DecodeTask = .{
        .sequence = 0,
        .element_index = 0,
        .first_record = 0,
        .record_count = 1,
        .input = &input,
        .layout = layout,
        .endian = .little,
        .pool = pool,
        .slot_id = slot,
    };
    task.cancel_requested.store(true, .release);
    try std.testing.expectError(error.Cancelled, task.execute());
    try std.testing.expectEqual(internal.execution.task.State.cancelled, task.state);
    pool.cancel(slot);
}
