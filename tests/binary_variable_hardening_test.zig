//! Phase 10 Milestone 6B: end-to-end binary-list memory and lifetime stress.
//! All fixtures are generated independently of the scanner/decoder, using
//! deterministic records with two unrelated list cardinalities.
const std = @import("std");
const internals = @import("zply_internals");
const support = @import("streaming_support.zig");
const Parser = internals.parser.Parser;

const Fixture = struct {
    bytes: []u8,
    count: usize,

    fn deinit(self: Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn makeFixture(allocator: std.mem.Allocator, count: usize, endian: std.builtin.Endian) !Fixture {
    const encoding = if (endian == .little) "binary_little_endian" else "binary_big_endian";
    const header = try std.fmt.allocPrint(
        allocator,
        "ply\nformat {s} 1.0\nelement face {d}\nproperty list uchar uint indices\nproperty float score\nproperty list ushort uchar flags\nend_header\n",
        .{ encoding, count },
    );
    defer allocator.free(header);
    var body_len: usize = 0;
    for (0..count) |i| {
        body_len += 1 + (i % 6) * 4 + 4 + 2 + ((i / 3) % 4);
    }
    const bytes = try allocator.alloc(u8, header.len + body_len + 2);
    @memcpy(bytes[0..header.len], header);
    var cursor = header.len;
    for (0..count) |i| {
        const n = i % 6;
        bytes[cursor] = @intCast(n);
        cursor += 1;
        for (0..n) |j| {
            std.mem.writeInt(u32, bytes[cursor..][0..4], @intCast(i * 7 + j), endian);
            cursor += 4;
        }
        const bits: u32 = @bitCast(@as(f32, @floatFromInt(i)));
        std.mem.writeInt(u32, bytes[cursor..][0..4], bits, endian);
        cursor += 4;
        const m = (i / 3) % 4;
        std.mem.writeInt(u16, bytes[cursor..][0..2], @intCast(m), endian);
        cursor += 2;
        for (0..m) |j| {
            bytes[cursor] = @intCast((i + j) % 251);
            cursor += 1;
        }
    }
    std.debug.assert(cursor == header.len + body_len);
    bytes[cursor] = 0xcc;
    bytes[cursor + 1] = 0xdd;
    return .{ .bytes = bytes, .count = count };
}

fn verify(io: std.Io, reader: *std.Io.Reader, count: usize, ordered: bool, chunk_bytes: usize, budget_bytes: usize) !u64 {
    var parser = try Parser.init(std.testing.allocator, io, reader, .{
        .chunk_size = chunk_bytes,
        .memory_budget = budget_bytes,
        .preserve_order = ordered,
    });
    defer parser.deinit();
    const seen = try std.testing.allocator.alloc(bool, count);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var records: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(usize, 0), info.element_index);
        const indices = try batch.listColumn(0);
        const scores = try batch.typedColumn(f32, 1);
        const flags = try batch.listColumn(2);
        for (0..info.record_count) |row| {
            const i = @as(usize, @intCast(info.first_record)) + row;
            try std.testing.expect(i < count);
            try std.testing.expect(!seen[i]);
            seen[i] = true;
            records += 1;
            const values = indices.row(row).?.u32;
            try std.testing.expectEqual(i % 6, values.len);
            for (values, 0..) |v, j| try std.testing.expectEqual(@as(u32, @intCast(i * 7 + j)), v);
            try std.testing.expectEqual(@as(f32, @floatFromInt(i)), scores[row]);
            const labels = flags.row(row).?.u8;
            try std.testing.expectEqual((i / 3) % 4, labels.len);
            for (labels, 0..) |v, j| try std.testing.expectEqual(@as(u8, @intCast((i + j) % 251)), v);
        }
        const stats = parser.memoryStats();
        try std.testing.expect(stats.peak_total_bytes <= budget_bytes);
        try std.testing.expect(stats.live_bytes + stats.reserved_bytes <= budget_bytes);
    }
    try std.testing.expectEqual(count, records);
    for (seen) |found| try std.testing.expect(found);
    try std.testing.expectEqual(@as(u8, 0xcc), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0xdd), try reader.takeByte());
    try std.testing.expectEqual(@as(usize, 0), parser.executionStats().active_decodes);
    return parser.executionStats().native_submissions;
}

test "binary variable mixed two-list records preserve identity through fragmented input and small budget" {
    inline for (.{ .little, .big }) |endian| {
        const fixture = try makeFixture(std.testing.allocator, 2048, endian);
        defer fixture.deinit(std.testing.allocator);
        inline for (.{ true, false }) |ordered| {
            var fragmented = support.FragmentingReader.init(fixture.bytes, &.{ 3, 1, 7, 2 }, 0);
            _ = try verify(std.testing.io, fragmented.reader(), fixture.count, ordered, 512, 192 * 1024);
        }
    }
}

test "binary variable threaded ordered and unordered output is exact under many chunks" {
    const fixture = try makeFixture(std.testing.allocator, 30_000, .little);
    defer fixture.deinit(std.testing.allocator);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    inline for (.{ true, false }) |ordered| {
        var reader: std.Io.Reader = .fixed(fixture.bytes);
        const submissions = try verify(threaded.io(), &reader, fixture.count, ordered, 128 * 1024, 4 * 1024 * 1024);
        try std.testing.expect(submissions > 0);
    }
}

test "binary variable terminal truncation leaves prior chunks readable and never publishes a partial record" {
    const fixture = try makeFixture(std.testing.allocator, 513, .big);
    defer fixture.deinit(std.testing.allocator);
    // Two trailer bytes plus the last two bytes of the final record.
    var reader: std.Io.Reader = .fixed(fixture.bytes[0 .. fixture.bytes.len - 4]);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 256,
        .memory_budget = 256 * 1024,
    });
    defer parser.deinit();
    var consumed: usize = 0;
    var failed = false;
    while (true) {
        const next_value = parser.next() catch |err| {
            try std.testing.expect(err == error.TruncatedListPayload or err == error.TruncatedListCount or err == error.TruncatedRecord);
            failed = true;
            break;
        };
        const value = next_value orelse break;
        var batch = value;
        defer batch.release();
        consumed += batch.info().record_count;
    }
    try std.testing.expect(failed);
    try std.testing.expectEqual(fixture.count - 1, consumed);
    try std.testing.expect(parser.binaryDiagnostic() != null);
    try std.testing.expectEqual(Parser.State.failed, parser.state);
    try std.testing.expectEqual(@as(usize, 0), parser.executionStats().active_decodes);
    try std.testing.expect(parser.memoryStats().peak_total_bytes <= 256 * 1024);
}

test "binary variable early threaded parser teardown cancels or joins unpublished tasks" {
    const fixture = try makeFixture(std.testing.allocator, 30_000, .little);
    defer fixture.deinit(std.testing.allocator);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    for (0..3) |_| {
        var reader: std.Io.Reader = .fixed(fixture.bytes);
        var parser = try Parser.init(std.testing.allocator, threaded.io(), &reader, .{
            .chunk_size = 128 * 1024,
            .memory_budget = 4 * 1024 * 1024,
            .preserve_order = false,
        });
        const batch_value = (try parser.next()) orelse return error.UnexpectedEndOfInput;
        var batch = batch_value;
        try std.testing.expect(batch.info().record_count > 0);
        batch.release();
        // No reader rewind, and no future may access the parser's resources
        // after deinit. std.testing.allocator diagnoses leaked ownership.
        parser.deinit();
    }
}

test "binary variable oversized single list is not split and following records retain their offsets" {
    const header = "ply\nformat binary_big_endian 1.0\nelement face 3\nproperty list ushort int indices\nend_header\n";
    const large_items: usize = 8192;
    const bytes = try std.testing.allocator.alloc(u8, header.len + 2 + (2 + large_items * 4) + (2 + 4) + 1);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);
    var cursor = header.len;
    std.mem.writeInt(u16, bytes[cursor..][0..2], 0, .big);
    cursor += 2;
    std.mem.writeInt(u16, bytes[cursor..][0..2], @intCast(large_items), .big);
    cursor += 2;
    for (0..large_items) |j| {
        std.mem.writeInt(i32, bytes[cursor..][0..4], @intCast(j), .big);
        cursor += 4;
    }
    std.mem.writeInt(u16, bytes[cursor..][0..2], 1, .big);
    cursor += 2;
    std.mem.writeInt(i32, bytes[cursor..][0..4], -17, .big);
    cursor += 4;
    bytes[cursor] = 0xee;
    cursor += 1;
    try std.testing.expectEqual(bytes.len, cursor);

    var source = support.FragmentingReader.init(bytes, &.{ 1, 7, 2, 64 }, 0);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, source.reader(), .{
        .chunk_size = 512,
        .memory_budget = 2 * 1024 * 1024,
    });
    defer parser.deinit();
    var expected_record: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(u64, @intCast(expected_record)), info.first_record);
        const lists = try batch.listColumn(0);
        for (0..info.record_count) |row| {
            const items = lists.row(row).?.i32;
            switch (expected_record) {
                0 => try std.testing.expectEqual(@as(usize, 0), items.len),
                1 => {
                    try std.testing.expectEqual(large_items, items.len);
                    for (items, 0..) |item, j| try std.testing.expectEqual(@as(i32, @intCast(j)), item);
                },
                2 => try std.testing.expectEqualSlices(i32, &.{-17}, items),
                else => return error.UnexpectedRecord,
            }
            expected_record += 1;
        }
        try std.testing.expect(parser.memoryStats().peak_total_bytes <= 2 * 1024 * 1024);
    }
    try std.testing.expectEqual(@as(usize, 3), expected_record);
    try std.testing.expectEqual(@as(u8, 0xee), try source.reader().takeByte());
}

test "binary variable held list-column lease remains immutable while subsequent tasks complete" {
    const fixture = try makeFixture(std.testing.allocator, 8_000, .little);
    defer fixture.deinit(std.testing.allocator);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(fixture.bytes);
    var parser = try Parser.init(std.testing.allocator, threaded.io(), &reader, .{
        .chunk_size = 4 * 1024,
        .memory_budget = 2 * 1024 * 1024,
        .preserve_order = true,
    });
    defer parser.deinit();
    var held = (try parser.next()) orelse return error.UnexpectedEndOfInput;
    defer held.release();
    try std.testing.expectEqual(@as(u64, 0), held.info().first_record);
    try std.testing.expect(held.info().record_count > 6);
    const held_count = held.info().record_count;
    const held_indices = try held.listColumn(0);
    try std.testing.expectEqualSlices(u32, &.{ 35, 36, 37, 38, 39 }, held_indices.row(5).?.u32);
    var consumed = held_count;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        try std.testing.expectEqual(@as(u64, @intCast(consumed)), batch.info().first_record);
        consumed += batch.info().record_count;
        try std.testing.expect(parser.memoryStats().peak_total_bytes <= 2 * 1024 * 1024);
    }
    try std.testing.expectEqual(fixture.count, consumed);
    // If pool reuse or task cancellation mutated the leased slot, this
    // would read corrupted list offsets or list items.
    try std.testing.expectEqualSlices(u32, &.{ 35, 36, 37, 38, 39 }, held_indices.row(5).?.u32);
    try std.testing.expectEqual(@as(f32, 5), (try held.typedColumn(f32, 1))[5]);
    try std.testing.expect(parser.memoryStats().leased_bytes > 0);
}
