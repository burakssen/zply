const std = @import("std");
const internal = @import("zply_internals");

test "raw buffers have independent generation-checked ownership" {
    var pool = try internal.input.RawBufferPool.init(std.testing.allocator, 1);
    defer pool.deinit();
    const first = try pool.acquire(16);
    @memset(pool.writable(first)[0..16], 0xA5);
    const lease = pool.publish(first, 16);
    try std.testing.expectEqual(@as(u8, 0xA5), (try pool.get(lease.id, lease.generation))[0]);
    try std.testing.expectError(error.InvalidRawBuffer, pool.release(lease.id, lease.generation + 1));
    try pool.release(lease.id, lease.generation);
    const second = try pool.acquire(32);
    try std.testing.expectEqual(first, second);
}

test "task registry keeps stable slots and rejects stale generations" {
    var registry = try internal.execution.Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const task: internal.execution.DecodeTask = undefined;
    const lease = try registry.acquire(task);
    try std.testing.expectEqual(@as(usize, 1), registry.activeCount());
    _ = try registry.get(lease.id, lease.generation);
    try registry.release(lease.id, lease.generation);
    try std.testing.expectEqual(@as(usize, 0), registry.activeCount());
    try std.testing.expectError(error.InvalidTaskSlot, registry.get(lease.id, lease.generation));
}
