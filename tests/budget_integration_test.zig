const std = @import("std");
const ply = @import("zply");

const header = "ply\nformat binary_little_endian 1.0\n" ++
    "element item 4\nproperty double x\nproperty uchar id\nend_header\n";
const body: [36]u8 = @splat(0);

fn expectAccounted(parser: *const ply.Parser, backing: *const std.testing.FailingAllocator) !void {
    const stats = parser.memoryStats();
    try std.testing.expectEqual(backing.allocated_bytes - backing.freed_bytes, stats.live_bytes);
    try std.testing.expect(stats.live_bytes <= stats.budget_bytes);
    try std.testing.expect(stats.reserved_bytes <= stats.budget_bytes - stats.live_bytes);
    try std.testing.expect(stats.peak_total_bytes <= stats.budget_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
}

test "bootstrap header raw columns retained buffers and destruction are charged" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader: std.Io.Reader = .fixed(header ++ body);
    var options: ply.Options = .{};
    options.memory_budget = 64 * 1024;
    options.chunk_size = 18;
    var parser = try ply.Parser.init(backing.allocator(), std.testing.io, &reader, options);
    try expectAccounted(&parser, &backing);
    const initial = parser.memoryStats().live_bytes;
    var first = (try parser.next()).?;
    try expectAccounted(&parser, &backing);
    try std.testing.expect(parser.memoryStats().live_bytes > initial);
    try std.testing.expect(parser.memoryStats().raw_buffer_bytes > 0);
    try std.testing.expect(parser.memoryStats().decoded_buffer_bytes > 0);
    try std.testing.expect(parser.memoryStats().leased_bytes > 0);
    const leased = parser.memoryStats().live_bytes;
    first.release();
    try std.testing.expectEqual(leased, parser.memoryStats().live_bytes);
    try std.testing.expect(parser.memoryStats().retained_bytes > 0);
    var second = (try parser.next()).?;
    try expectAccounted(&parser, &backing);
    second.release();
    try std.testing.expect((try parser.next()) == null);
    parser.deinit();
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "budget refusal during header parsing releases bootstrap and partial header" {
    const large_comment: [8000]u8 = @splat('x');
    const text = "ply\nformat binary_little_endian 1.0\ncomment " ++ large_comment ++ "\nend_header\n";
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader: std.Io.Reader = .fixed(text);
    var options: ply.Options = .{};
    options.memory_budget = 4096;
    options.chunk_size = 1024;
    try std.testing.expectError(error.ResourceLimitExceeded, ply.Parser.init(backing.allocator(), std.testing.io, &reader, options));
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "adaptive body admission can succeed below the preferred chunk" {
    const h = "ply\nformat binary_little_endian 1.0\nelement item 32768\nproperty uchar value\nend_header\n";
    const data: [32768]u8 = @splat(7);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader: std.Io.Reader = .fixed(h ++ data);
    var options: ply.Options = .{};
    options.memory_budget = 32768;
    options.chunk_size = 32768;
    var parser = try ply.Parser.init(backing.allocator(), std.testing.io, &reader, options);
    defer parser.deinit();
    const before = reader.seek;
    var batch = (try parser.next()).?;
    try std.testing.expect(reader.seek > before);
    try std.testing.expect(batch.info().record_count < 32768);
    batch.release();
    try expectAccounted(&parser, &backing);
}

test "underlying allocator failure remains OutOfMemory" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader: std.Io.Reader = .fixed(header ++ body);
    var parser = try ply.Parser.init(backing.allocator(), std.testing.io, &reader, .{});
    defer parser.deinit();
    const before = reader.seek;
    backing.fail_index = backing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, parser.next());
    try std.testing.expectEqual(before, reader.seek);
    try expectAccounted(&parser, &backing);
}

test "every body preparation failure releases its pending reservation" {
    var saw_failure = false;
    var saw_success = false;
    for (0..12) |offset| {
        var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var reader: std.Io.Reader = .fixed(header ++ body);
        var parser = try ply.Parser.init(backing.allocator(), std.testing.io, &reader, .{});
        const body_start = reader.seek;
        backing.fail_index = backing.alloc_index + offset;
        if (parser.next()) |maybe_batch| {
            var batch = maybe_batch.?;
            batch.release();
            saw_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(body_start, reader.seek);
            try expectAccounted(&parser, &backing);
            backing.fail_index = std.math.maxInt(usize);
            var retry = (try parser.next()).?;
            retry.release();
            saw_failure = true;
        }
        parser.deinit();
        try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
    }
    try std.testing.expect(saw_failure);
    try std.testing.expect(saw_success);
}

test "adaptive admission reduces preferred batch size and completes" {
    const h = "ply\nformat binary_little_endian 1.0\nelement item 10000\nproperty uchar value\nend_header\n";
    const data: [10000]u8 = @splat(9);
    var reader: std.Io.Reader = .fixed(h ++ data);
    var options: ply.Options = .{};
    options.chunk_size = 4096;
    // Deliberately below the preferred raw+decoded payload, but above
    // bootstrap, metadata, one slot, and a feasible reduced batch.
    options.memory_budget = 8 * 1024;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();
    var first_count: ?usize = null;
    var seen: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        if (first_count == null) first_count = batch.info().record_count;
        seen += batch.info().record_count;
    }
    try std.testing.expectEqual(@as(usize, 10000), seen);
    try std.testing.expect(first_count.? < 4096);
    const stats = parser.memoryStats();
    try std.testing.expect(stats.peak_total_bytes <= options.memory_budget);
    try std.testing.expect(stats.batch_reductions > 0);
}

test "available incompatible schema storage is reclaimed at an element transition" {
    const h = "ply\nformat binary_little_endian 1.0\n" ++
        "element wide 1\nproperty double x\nproperty double y\n" ++
        // More than eight 16-byte chunks: the parser may fill its entire
        // speculative window before the first batch is returned.
        "element narrow 1000\nproperty uchar value\nend_header\n";
    const tail: [1000]u8 = @splat(7);
    const data = [_]u8{ 0, 0, 0, 0, 0, 0, 0xf0, 0x3f, 0, 0, 0, 0, 0, 0, 0, 0 } ++ tail;
    var reader: std.Io.Reader = .fixed(h ++ data);
    var options: ply.Options = .{};
    options.chunk_size = 16;
    options.memory_budget = 16 * 1024;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();
    var wide = (try parser.next()).?;
    wide.release();
    const before = parser.memoryStats().live_bytes;
    var narrow_count: usize = 0;
    {
        var narrow = (try parser.next()).?;
        // Release the lease even if any assertion fails, so the useful
        // failure is not masked by Pool.destroy()'s lease assertion.
        defer narrow.release();
        try std.testing.expectEqual(@as(usize, 1), narrow.columnCount());
        try std.testing.expectEqual(@as(u8, 7), (try narrow.typedColumn(u8, 0))[0]);
        narrow_count += narrow.info().record_count;
        try std.testing.expect(parser.memoryStats().live_bytes <= options.memory_budget);
        try std.testing.expect(parser.memoryStats().live_bytes <= before + 1024);
        // With input still pending after the first full scheduling window,
        // admission reclaims the released wide-schema column storage.
        try std.testing.expect(parser.memoryStats().pool_evictions > 0);
    }
    while (try parser.next()) |value| {
        var narrow = value;
        defer narrow.release();
        try std.testing.expectEqual(@as(usize, 1), narrow.columnCount());
        narrow_count += narrow.info().record_count;
    }
    try std.testing.expectEqual(@as(usize, 1000), narrow_count);
}
