//! End-to-end Phase 7 tests through the public reader-first API.
const std = @import("std");
const ply = @import("zply");

fn makeXyz(allocator: std.mem.Allocator, count: usize, endian: std.builtin.Endian) ![]u8 {
    const format = switch (endian) {
        .little => "binary_little_endian",
        .big => "binary_big_endian",
    };
    const header = try allocator.print(
        "ply\nformat {s} 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty float y\nproperty float z\nend_header\n",
        .{ format, count },
    );
    defer allocator.free(header);
    const total = try std.math.add(usize, header.len, try std.math.mul(usize, count, 12));
    const bytes = try allocator.alloc(u8, total);
    @memcpy(bytes[0..header.len], header);
    for (0..count) |i| {
        const start = header.len + 12 * i;
        const x: f32 = @floatFromInt(i);
        const y: f32 = @floatFromInt(i * 2);
        const z: f32 = @floatFromInt(i * 3);
        std.mem.writeInt(u32, bytes[start..][0..4], @bitCast(x), endian);
        std.mem.writeInt(u32, bytes[start + 4 ..][0..4], @bitCast(y), endian);
        std.mem.writeInt(u32, bytes[start + 8 ..][0..4], @bitCast(z), endian);
    }
    return bytes;
}

fn checkStream(io: std.Io, bytes: []const u8, count: usize, ordered: bool) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var options: ply.Options = .{};
    options.chunk_size = 128 * 1024;
    options.memory_budget = 4 * 1024 * 1024;
    options.preserve_order = ordered;
    var parser = try ply.Parser.init(std.testing.allocator, io, &reader, options);
    defer parser.deinit();

    const seen = try std.testing.allocator.alloc(bool, count);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var next_sequence: u64 = 0;
    var next_record: u64 = 0;
    var delivered: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(usize, 0), info.element_index);
        if (ordered) {
            try std.testing.expectEqual(next_sequence, info.sequence);
            try std.testing.expectEqual(next_record, info.first_record);
            next_sequence += 1;
            next_record += info.record_count;
        }
        const x = try batch.typedColumn(f32, 0);
        const y = try batch.typedColumn(f32, 1);
        const z = try batch.typedColumn(f32, 2);
        try std.testing.expectEqual(info.record_count, x.len);
        for (x, y, z, 0..) |vx, vy, vz, j| {
            const record = @as(usize, @intCast(info.first_record)) + j;
            try std.testing.expect(record < count);
            try std.testing.expect(!seen[record]);
            seen[record] = true;
            try std.testing.expectEqual(@as(f32, @floatFromInt(record)), vx);
            try std.testing.expectEqual(@as(f32, @floatFromInt(record * 2)), vy);
            try std.testing.expectEqual(@as(f32, @floatFromInt(record * 3)), vz);
        }
        delivered += x.len;
        const stats = parser.memoryStats();
        try std.testing.expect(stats.live_bytes + stats.reserved_bytes <= stats.budget_bytes);
        try std.testing.expect(stats.peak_total_bytes <= stats.budget_bytes);
    }
    try std.testing.expectEqual(count, delivered);
    if (ordered) try std.testing.expectEqual(@as(u64, @intCast(count)), next_record);
    for (seen) |visited| try std.testing.expect(visited);
    try std.testing.expect((try parser.next()) == null);
}

test "native concurrent decoding preserves exact f32 values and sequence" {
    const count = 120_000;
    const source = try makeXyz(std.testing.allocator, count, .little);
    defer std.testing.allocator.free(source);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    try checkStream(io_impl.io(), source, count, true);
    try checkStream(io_impl.io(), source, count, false);
}

test "big-endian decoding is identical in ordered and unordered mode" {
    const count = 120_000;
    const source = try makeXyz(std.testing.allocator, count, .big);
    defer std.testing.allocator.free(source);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    try checkStream(io_impl.io(), source, count, true);
    try checkStream(io_impl.io(), source, count, false);
}

test "single-context fallback follows the same decoding path" {
    const count = 12_000;
    const source = try makeXyz(std.testing.allocator, count, .little);
    defer std.testing.allocator.free(source);
    try checkStream(std.testing.io, source, count, true);
    try checkStream(std.testing.io, source, count, false);
}

test "read-ahead failure preserves earlier complete ordered batches" {
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 20000\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    const source = try std.testing.allocator.alloc(u8, header.len + 128 * 1024 + 100);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..header.len], header);
    @memset(source[header.len..], 0);
    var reader: std.Io.Reader = .fixed(source);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var parser = try ply.Parser.init(std.testing.allocator, io_impl.io(), &reader, .{ .chunk_size = 128 * 1024 });
    defer parser.deinit();
    var first = (try parser.next()).?;
    try std.testing.expectEqual(@as(u64, 0), first.info().sequence);
    try std.testing.expect(first.info().record_count > 0);
    first.release();
    try std.testing.expectError(error.TruncatedBody, parser.next());
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

test "early parser destruction joins undelivered concurrent work" {
    const source = try makeXyz(std.testing.allocator, 150_000, .little);
    defer std.testing.allocator.free(source);
    var reader: std.Io.Reader = .fixed(source);
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    var parser = try ply.Parser.init(std.testing.allocator, io_impl.io(), &reader, .{ .chunk_size = 128 * 1024 });
    var first = (try parser.next()).?;
    first.release();
    parser.deinit();
}

test "global batch sequence and element-local offsets survive schema changes" {
    const h = "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 2\nproperty uchar label\n" ++
        "element marker 80000\n" ++
        "element camera 3\nproperty ushort id\nend_header\n";
    const bytes = h ++ [_]u8{ 4, 7, 10, 0, 20, 0, 30, 0 };
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 4 });
    defer parser.deinit();
    var sequence: u64 = 0;
    var elements: [3]usize = @splat(0);
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(sequence, info.sequence);
        try std.testing.expect(info.element_index < elements.len);
        try std.testing.expectEqual(@as(u64, @intCast(elements[info.element_index])), info.first_record);
        elements[info.element_index] += info.record_count;
        sequence += 1;
        if (info.element_index == 1) {
            try std.testing.expectEqual(@as(usize, 0), batch.columnCount());
        } else if (info.element_index == 0) {
            try std.testing.expect(batch.columnCount() == 1);
        } else {
            const ids = try batch.typedColumn(u16, 0);
            for (ids, 0..) |v, i| {
                const index = @as(usize, @intCast(info.first_record)) + i;
                try std.testing.expectEqual(@as(u16, @intCast((index + 1) * 10)), v);
            }
        }
    }
    try std.testing.expectEqualSlices(usize, &.{ 2, 80_000, 3 }, &elements);
    try std.testing.expectEqual(@as(u64, 5), sequence);
}

test "3 million XYZ records retain exact-once delivery under native concurrency" {
    // End-to-end stress test, not merely a decoding microbenchmark.
    const count = 3_000_000;
    const source = try makeXyz(std.testing.allocator, count, .little);
    defer std.testing.allocator.free(source);
    var executor: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer executor.deinit();
    try checkStream(executor.io(), source, count, true);
    try checkStream(executor.io(), source, count, false);
}

fn makeMixed(allocator: std.mem.Allocator, count: usize, endian: std.builtin.Endian) ![]u8 {
    const format = switch (endian) {
        .little => "binary_little_endian",
        .big => "binary_big_endian",
    };
    const header = try allocator.print(
        "ply\nformat {s} 1.0\nelement vertex {d}\n" ++
            "property uchar classification\nproperty double x\n" ++
            "property float intensity\nproperty double y\n" ++
            "property ushort point_source\nproperty double z\nend_header\n",
        .{ format, count },
    );
    defer allocator.free(header);
    const stride: usize = 31;
    const bytes = try allocator.alloc(u8, header.len + try std.math.mul(usize, count, stride));
    @memcpy(bytes[0..header.len], header);
    for (0..count) |i| {
        const pos = header.len + i * stride;
        const x: f64 = @floatFromInt(i);
        const y: f64 = @floatFromInt(i * 2);
        const z: f64 = @floatFromInt(i * 3);
        const intensity: f32 = @floatFromInt(i % 1000);
        bytes[pos] = @intCast(i % 251);
        std.mem.writeInt(u64, bytes[pos + 1 ..][0..8], @bitCast(x), endian);
        std.mem.writeInt(u32, bytes[pos + 9 ..][0..4], @bitCast(intensity), endian);
        std.mem.writeInt(u64, bytes[pos + 13 ..][0..8], @bitCast(y), endian);
        std.mem.writeInt(u16, bytes[pos + 21 ..][0..2], @intCast(i % 65536), endian);
        std.mem.writeInt(u64, bytes[pos + 23 ..][0..8], @bitCast(z), endian);
    }
    return bytes;
}

fn checkMixed(io: std.Io, source: []const u8, count: usize, ordered: bool) !void {
    var reader: std.Io.Reader = .fixed(source);
    var parser = try ply.Parser.init(std.testing.allocator, io, &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 4 * 1024 * 1024,
        .preserve_order = ordered,
    });
    defer parser.deinit();
    const seen = try std.testing.allocator.alloc(bool, count);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var total: usize = 0;
    var next_sequence: u64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        if (ordered) {
            try std.testing.expectEqual(next_sequence, info.sequence);
            next_sequence += 1;
        }
        try std.testing.expectEqual(@as(usize, 6), batch.columnCount());
        const classifications = try batch.typedColumn(u8, 0);
        const xs = try batch.typedColumn(f64, 1);
        const intensities = try batch.typedColumn(f32, 2);
        const ys = try batch.typedColumn(f64, 3);
        const sources = try batch.typedColumn(u16, 4);
        const zs = try batch.typedColumn(f64, 5);
        for (0..info.record_count) |j| {
            const i = @as(usize, @intCast(info.first_record)) + j;
            try std.testing.expect(i < count);
            try std.testing.expect(!seen[i]);
            seen[i] = true;
            try std.testing.expectEqual(@as(u8, @intCast(i % 251)), classifications[j]);
            try std.testing.expectEqual(@as(f64, @floatFromInt(i)), xs[j]);
            try std.testing.expectEqual(@as(f32, @floatFromInt(i % 1000)), intensities[j]);
            try std.testing.expectEqual(@as(f64, @floatFromInt(i * 2)), ys[j]);
            try std.testing.expectEqual(@as(u16, @intCast(i % 65536)), sources[j]);
            try std.testing.expectEqual(@as(f64, @floatFromInt(i * 3)), zs[j]);
        }
        total += info.record_count;
        const memory = parser.memoryStats();
        try std.testing.expect(memory.peak_total_bytes <= memory.budget_bytes);
    }
    try std.testing.expectEqual(count, total);
    for (seen) |value| try std.testing.expect(value);
}

test "mixed-width binary records decode exactly with both endians and order modes" {
    const count = 80_000;
    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        const data = try makeMixed(std.testing.allocator, count, endian);
        defer std.testing.allocator.free(data);
        try checkMixed(io_impl.io(), data, count, true);
        try checkMixed(io_impl.io(), data, count, false);
    }
}

test "leased columns remain stable across new decode operations" {
    const source = try makeXyz(std.testing.allocator, 80_000, .little);
    defer std.testing.allocator.free(source);
    var reader: std.Io.Reader = .fixed(source);
    var executor: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer executor.deinit();
    var parser = try ply.Parser.init(std.testing.allocator, executor.io(), &reader, .{
        .chunk_size = 64 * 1024,
        .memory_budget = 4 * 1024 * 1024,
    });
    defer parser.deinit();
    var first = (try parser.next()).?;
    defer first.release();
    const xs = try first.typedColumn(f32, 0);
    const first_count = first.info().record_count;
    try std.testing.expectEqual(@as(f32, 0), xs[0]);
    try std.testing.expectEqual(@as(f32, @floatFromInt(first_count - 1)), xs[first_count - 1]);

    var delivered: usize = first_count;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        delivered += batch.info().record_count;
        try std.testing.expectEqual(@as(f32, 0), xs[0]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(first_count - 1)), xs[first_count - 1]);
    }
    try std.testing.expectEqual(@as(usize, 80_000), delivered);
}

// Verify the native execution-capacity settings against the same public API.
// No worker-count parameter is added to Parser.Options. With a roomy budget,
// the eight-slot admission window should fill on sufficiently large input,
// independent of which executor capacity the caller selects.
test "2, 4, and 8 executor capacities preserve every record and bounded admission" {
    const count = 300_000;
    const source = try makeXyz(std.testing.allocator, count, .little);
    defer std.testing.allocator.free(source);

    inline for (.{ 2, 4, 8 }) |limit| {
        var executor: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(limit) });
        defer executor.deinit();
        try checkStream(executor.io(), source, count, true);
        try checkStream(executor.io(), source, count, false);
    }
}
