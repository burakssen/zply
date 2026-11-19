//! Opt-in Phase 10 scale validation: 3M/10M variable-length records.
//!
//! The non-seekable virtual Reader generates records on demand: no multi-GB
//! input buffer is allocated, and every returned list item is independently
//! validated. Run with:
//!   zig build test-binary-variable-large -Doptimize=ReleaseFast
const std = @import("std");
const internal = @import("zply_internals");
const Parser = internal.parser.Parser;

const virtual_vtable = std.Io.Reader.VTable{ .stream = virtualStream };
const VirtualReader = struct {
    header: []const u8,
    record_count: usize,
    endian: std.builtin.Endian,
    header_pos: usize = 0,
    record_index: usize = 0,
    record_pos: usize = 0,
    record: [25]u8 = undefined,
    staging: [4096]u8 = undefined,
    buffer: [8192]u8 = undefined,
    base: std.Io.Reader = .{
        .vtable = &virtual_vtable,
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },

    fn reader(self: *VirtualReader) *std.Io.Reader {
        self.base.buffer = &self.buffer;
        return &self.base;
    }

    fn width(index: usize) usize {
        return 1 + (index % 6) * 4 + 4;
    }

    fn row(self: *VirtualReader, index: usize) []const u8 {
        const items = index % 6;
        self.record[0] = @intCast(items);
        for (0..items) |j| {
            std.mem.writeInt(u32, self.record[1 + j * 4 ..][0..4], @intCast(index * 5 + j), self.endian);
        }
        const score: f32 = @floatFromInt(index);
        std.mem.writeInt(u32, self.record[1 + items * 4 ..][0..4], @bitCast(score), self.endian);
        return self.record[0..width(index)];
    }

    fn advance(self: *VirtualReader, delivered: usize) void {
        var remaining = delivered;
        while (remaining != 0) {
            if (self.header_pos < self.header.len) {
                const n = @min(remaining, self.header.len - self.header_pos);
                self.header_pos += n;
                remaining -= n;
            } else {
                const n = @min(remaining, width(self.record_index) - self.record_pos);
                self.record_pos += n;
                remaining -= n;
                if (self.record_pos == width(self.record_index)) {
                    self.record_index += 1;
                    self.record_pos = 0;
                }
            }
        }
    }
};

fn virtualStream(base: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *VirtualReader = @alignCast(@fieldParentPtr("base", base));
    const target = @min(self.staging.len, @backingInt(limit));
    var staged: usize = 0;
    var header_pos = self.header_pos;
    var record_index = self.record_index;
    var record_pos = self.record_pos;
    while (staged < target) {
        const in_header = header_pos < self.header.len;
        const remaining: []const u8 = if (in_header)
            self.header[header_pos..]
        else if (record_index < self.record_count)
            self.row(record_index)[record_pos..]
        else
            break;
        const n = @min(remaining.len, target - staged);
        @memcpy(self.staging[staged..][0..n], remaining[0..n]);
        staged += n;
        if (in_header) {
            header_pos += n;
        } else {
            record_pos += n;
            if (record_pos == VirtualReader.width(record_index)) {
                record_index += 1;
                record_pos = 0;
            }
        }
    }
    if (staged == 0) return error.EndOfStream;
    const written = try writer.write(self.staging[0..staged]);
    self.advance(written);
    return written;
}

fn runScale(count: usize, endian: std.builtin.Endian) !void {
    const encoding = if (endian == .little) "binary_little_endian" else "binary_big_endian";
    const header = try std.fmt.allocPrint(
        std.testing.allocator,
        "ply\nformat {s} 1.0\nelement face {d}\nproperty list uchar uint indices\nproperty float score\nend_header\n",
        .{ encoding, count },
    );
    defer std.testing.allocator.free(header);
    var source = VirtualReader{ .header = header, .record_count = count, .endian = endian };
    const budget: usize = 16 * 1024 * 1024;
    var parser = try Parser.init(std.testing.allocator, std.testing.io, source.reader(), .{
        .chunk_size = 256 * 1024,
        .memory_budget = budget,
        .preserve_order = true,
    });
    defer parser.deinit();
    var next_record: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(usize, 0), info.element_index);
        try std.testing.expectEqual(@as(u64, @intCast(next_record)), info.first_record);
        const lists = try batch.listColumn(0);
        const scores = try batch.typedColumn(f32, 1);
        for (0..info.record_count) |row| {
            const i = next_record + row;
            const items = lists.row(row).?.u32;
            try std.testing.expectEqual(i % 6, items.len);
            for (items, 0..) |item, j| try std.testing.expectEqual(@as(u32, @intCast(i * 5 + j)), item);
            try std.testing.expectEqual(@as(f32, @floatFromInt(i)), scores[row]);
        }
        next_record += info.record_count;
        const mem = parser.memoryStats();
        try std.testing.expect(mem.peak_total_bytes <= budget);
        try std.testing.expect(mem.live_bytes + mem.reserved_bytes <= budget);
    }
    try std.testing.expectEqual(count, next_record);
    try std.testing.expectEqual(count, source.record_index);
    try std.testing.expectEqual(@as(usize, 0), source.record_pos);
    try std.testing.expectEqual(@as(usize, 0), parser.executionStats().active_decodes);
}

test "3M non-seekable variable binary records with changing list lengths little endian" {
    try runScale(3_000_000, .little);
}

test "10M non-seekable variable binary records with changing list lengths big endian" {
    try runScale(10_000_000, .big);
}
