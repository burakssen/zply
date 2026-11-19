//! Deterministic, constant-source-memory ASCII PLY dataset verification.
//!
//! A virtual non-seekable Reader supplies a small header followed by a
//! repeating four-record pattern. The source is never materialized as a
//! multi-million-record byte array. Every decoded row is checked in order.
const std = @import("std");
const z = @import("zply");

pub const Kind = enum { xyz_f32, xyz_f64, xyzrgb, wide, triangles, polygons, empty, sequence };

const Spec = struct {
    name: []const u8,
    properties: []const u8,
    rows: [4][]const u8,
};

fn spec(kind: Kind) Spec {
    return switch (kind) {
        .xyz_f32 => .{
            .name = "vertex",
            .properties = "property float x\nproperty float y\nproperty float z\n",
            .rows = .{
                "1.25 -2.5 3.75\n", "0 -0 100\n", "-123.5 .5 9e2\n", "2 4 -8\n",
            },
        },
        .xyz_f64 => .{
            .name = "vertex",
            .properties = "property double x\nproperty double y\nproperty double z\n",
            .rows = .{
                "0.0 -0.0 1.25\n", "1.23456789012345 2.5e-8 -3.5\n",
                "3 4 5\n", "-12.75 .5 9e3\n",
            },
        },
        .xyzrgb => .{
            .name = "vertex",
            .properties = "property float x\nproperty double z\nproperty uchar red\nproperty ushort intensity\nproperty short classification\n",
            .rows = .{
                "1.5 -2.75 255 65000 -2\n", "-0.0 123.125 0 0 32767\n",
                ".25 -1e-3 128 256 -32768\n", "10.0 0.0 10 65535 42\n",
            },
        },
        .wide => .{
            .name = "custom",
            .properties = "property uchar blue\nproperty double z\nproperty int classification\n" ++
                "property float x\nproperty double y\nproperty ushort intensity\n" ++
                "property char flag\nproperty uint id\nproperty short code\nproperty float confidence\n",
            .rows = .{
                "255 1.25 -3 0.5 -0.0 65535 -128 4294967295 32767 .25\n",
                "0 -2.5e-2 10 -1 12.75 0 127 0 -32768 1e-3\n",
                "12 0 0 3 4 100 -1 12 -5 0\n",
                "42 9e2 200 -12.5 -3.125 4096 1 98765 1234 .75\n",
            },
        },
        .triangles => .{
            .name = "face",
            .properties = "property uchar material\nproperty list uchar int indices\n",
            .rows = .{
                "10 3 1 2 3\n", "20 3 100 101 102\n",
                "30 3 -1 0 1\n", "40 3 200000 200001 200002\n",
            },
        },
        .polygons => .{
            .name = "polygon",
            .properties = "property double area\nproperty list ushort int vertices\n" ++
                "property uchar kind\nproperty list uchar float weights\nproperty double timestamp\n",
            .rows = .{
                "0.0 0 7 0 100.0\n",
                "1.5 3 1 2 3 4 3 .25 .5 .75 101.0\n",
                "2.5 4 -1 0 1 2 5 4 1.0 2.0 3.0 4.0 102.0\n",
                "3.5 7 0 1 2 3 4 5 6 9 2 0.125 -0.25 103.0\n",
            },
        },
        .empty => .{ .name = "blank", .properties = "", .rows = .{ "\n", "\n", "\n", "\n" } },
        // Unlike the other dataset families, these rows encode the global
        // record index. Repeating an old four-record block cannot pass.
        .sequence => .{
            .name = "indexed",
            .properties = "property uint id\nproperty int neg_id\nproperty ushort bucket\n",
            .rows = .{ "", "", "", "" }, // Generated dynamically by VirtualReader.
        },
    };
}

const virtual_reader_vtable = std.Io.Reader.VTable{ .stream = virtualStream };

/// A non-seekable reader with O(1) source memory regardless of record count.
/// Input is genuinely delivered through the std.Io.Reader stream interface.
const VirtualReader = struct {
    header: []const u8,
    rows: [4][]const u8,
    record_count: usize,
    unique_rows: bool = false,
    dynamic_row: [64]u8 = undefined,
    header_pos: usize = 0,
    record_index: usize = 0,
    record_pos: usize = 0,
    buffer: [8192]u8 = undefined,
    staging: [4096]u8 = undefined,
    base: std.Io.Reader = .{
        .vtable = &virtual_reader_vtable,
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },

    fn reader(self: *VirtualReader) *std.Io.Reader {
        self.base.buffer = &self.buffer;
        return &self.base;
    }

    fn rowAt(self: *VirtualReader, index: usize) []const u8 {
        if (!self.unique_rows) return self.rows[index % 4];
        const signed: i32 = @intCast(index);
        const bucket: u16 = @intCast(index % 65536);
        return std.fmt.bufPrint(&self.dynamic_row, "{d} {d} {d}\n", .{
            index, -signed, bucket,
        }) catch unreachable;
    }

    fn advance(self: *VirtualReader, n: usize) void {
        var remaining = n;
        while (remaining > 0) {
            if (self.header_pos < self.header.len) {
                const take = @min(remaining, self.header.len - self.header_pos);
                self.header_pos += take;
                remaining -= take;
            } else {
                const line = self.rowAt(self.record_index);
                const take = @min(remaining, line.len - self.record_pos);
                self.record_pos += take;
                remaining -= take;
                if (self.record_pos == line.len) {
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
            self.rowAt(record_index)[record_pos..]
        else
            break;

        const n = @min(remaining.len, target - staged);
        @memcpy(self.staging[staged..][0..n], remaining[0..n]);
        staged += n;
        if (in_header) {
            header_pos += n;
        } else {
            record_pos += n;
            if (record_pos == self.rowAt(record_index).len) {
                record_index += 1;
                record_pos = 0;
            }
        }
    }
    if (staged == 0) return error.EndOfStream;
    // Exactly one writer operation, as in the existing fragmented-reader
    // test double. Only bytes actually written advance the logical source.
    const written = try writer.write(self.staging[0..staged]);
    self.advance(written);
    return written;
}

fn expectScalar(comptime T: type, actual: T, expected: T) !void {
    // Comparing bit patterns also verifies negative zero for f32/f64.
    switch (@typeInfo(T)) {
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            try std.testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(actual)));
        },
        else => try std.testing.expectEqual(expected, actual),
    }
}

fn verifyBatch(kind: Kind, batch: *const z.Batch) !void {
    const info = batch.info();
    const count = info.record_count;
    switch (kind) {
        .xyz_f32 => {
            const x = try batch.typedColumn(f32, 0);
            const y = try batch.typedColumn(f32, 1);
            const zz = try batch.typedColumn(f32, 2);
            try std.testing.expectEqual(count, x.len);
            for (0..count) |i| {
                const p = (@as(usize, @intCast(info.first_record)) + i) % 4;
                const expected: [4][3]f32 = .{
                    .{ 1.25, -2.5, 3.75 }, .{ 0, -0.0, 100 },
                    .{ -123.5, 0.5, 900 }, .{ 2, 4, -8 },
                };
                try expectScalar(f32, x[i], expected[p][0]);
                try expectScalar(f32, y[i], expected[p][1]);
                try expectScalar(f32, zz[i], expected[p][2]);
            }
        },
        .xyz_f64 => {
            const x = try batch.typedColumn(f64, 0);
            const y = try batch.typedColumn(f64, 1);
            const zz = try batch.typedColumn(f64, 2);
            try std.testing.expectEqual(count, x.len);
            for (0..count) |i| {
                const p = (@as(usize, @intCast(info.first_record)) + i) % 4;
                const expected: [4][3]f64 = .{
                    .{ 0, -0.0, 1.25 }, .{ 1.23456789012345, 2.5e-8, -3.5 },
                    .{ 3, 4, 5 }, .{ -12.75, 0.5, 9000 },
                };
                try expectScalar(f64, x[i], expected[p][0]);
                try expectScalar(f64, y[i], expected[p][1]);
                try expectScalar(f64, zz[i], expected[p][2]);
            }
        },
        .xyzrgb => {
            const x = try batch.typedColumn(f32, 0);
            const zz = try batch.typedColumn(f64, 1);
            const red = try batch.typedColumn(u8, 2);
            const intensity = try batch.typedColumn(u16, 3);
            const classification = try batch.typedColumn(i16, 4);
            try std.testing.expectEqual(count, x.len);
            for (0..count) |i| {
                const p = (@as(usize, @intCast(info.first_record)) + i) % 4;
                const ex: [4]f32 = .{ 1.5, -0.0, 0.25, 10 };
                const ez: [4]f64 = .{ -2.75, 123.125, -0.001, 0 };
                const er: [4]u8 = .{ 255, 0, 128, 10 };
                const ei: [4]u16 = .{ 65000, 0, 256, 65535 };
                const ec: [4]i16 = .{ -2, 32767, -32768, 42 };
                try expectScalar(f32, x[i], ex[p]);
                try expectScalar(f64, zz[i], ez[p]);
                try std.testing.expectEqual(er[p], red[i]);
                try std.testing.expectEqual(ei[p], intensity[i]);
                try std.testing.expectEqual(ec[p], classification[i]);
            }
        },
        .wide => {
            const blue = try batch.typedColumn(u8, 0);
            const zz = try batch.typedColumn(f64, 1);
            const cls = try batch.typedColumn(i32, 2);
            const x = try batch.typedColumn(f32, 3);
            const y = try batch.typedColumn(f64, 4);
            const intensity = try batch.typedColumn(u16, 5);
            const flag = try batch.typedColumn(i8, 6);
            const id = try batch.typedColumn(u32, 7);
            const code = try batch.typedColumn(i16, 8);
            const confidence = try batch.typedColumn(f32, 9);
            try std.testing.expectEqual(@as(usize, 10), batch.columnCount());
            for (0..count) |i| {
                const p = (@as(usize, @intCast(info.first_record)) + i) % 4;
                try std.testing.expectEqual(([_]u8{ 255, 0, 12, 42 })[p], blue[i]);
                try expectScalar(f64, zz[i], ([_]f64{ 1.25, -0.025, 0, 900 })[p]);
                try std.testing.expectEqual(([_]i32{ -3, 10, 0, 200 })[p], cls[i]);
                try expectScalar(f32, x[i], ([_]f32{ 0.5, -1, 3, -12.5 })[p]);
                try expectScalar(f64, y[i], ([_]f64{ -0.0, 12.75, 4, -3.125 })[p]);
                try std.testing.expectEqual(([_]u16{ 65535, 0, 100, 4096 })[p], intensity[i]);
                try std.testing.expectEqual(([_]i8{ -128, 127, -1, 1 })[p], flag[i]);
                try std.testing.expectEqual(([_]u32{ 4294967295, 0, 12, 98765 })[p], id[i]);
                try std.testing.expectEqual(([_]i16{ 32767, -32768, -5, 1234 })[p], code[i]);
                try expectScalar(f32, confidence[i], ([_]f32{ 0.25, 0.001, 0, 0.75 })[p]);
            }
        },
        .triangles => {
            try std.testing.expectEqual(@as(usize, 1), count);
            const p = @as(usize, @intCast(info.first_record % 4));
            const material = try batch.typedColumn(u8, 0);
            const indices = try batch.listColumn(1);
            try std.testing.expectEqual(([_]u8{ 10, 20, 30, 40 })[p], material[0]);
            try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, indices.offsets);
            const values = indices.row(0).?.i32;
            const expected: [4][3]i32 = .{
                .{ 1, 2, 3 }, .{ 100, 101, 102 },
                .{ -1, 0, 1 }, .{ 200000, 200001, 200002 },
            };
            try std.testing.expectEqualSlices(i32, &expected[p], values);
        },
        .polygons => {
            try std.testing.expectEqual(@as(usize, 1), count);
            const p = @as(usize, @intCast(info.first_record % 4));
            const area = try batch.typedColumn(f64, 0);
            const vertices = try batch.listColumn(1);
            const kind_col = try batch.typedColumn(u8, 2);
            const weights = try batch.listColumn(3);
            const timestamp = try batch.typedColumn(f64, 4);
            try expectScalar(f64, area[0], ([_]f64{ 0, 1.5, 2.5, 3.5 })[p]);
            try std.testing.expectEqual(([_]u8{ 7, 4, 5, 9 })[p], kind_col[0]);
            try expectScalar(f64, timestamp[0], ([_]f64{ 100, 101, 102, 103 })[p]);
            const v = vertices.row(0).?.i32;
            const w = weights.row(0).?.f32;
            try std.testing.expectEqual(([_]usize{ 0, 3, 4, 7 })[p], v.len);
            try std.testing.expectEqual(([_]usize{ 0, 3, 4, 2 })[p], w.len);
            try std.testing.expectEqualSlices(usize, &.{ 0, v.len }, vertices.offsets);
            try std.testing.expectEqualSlices(usize, &.{ 0, w.len }, weights.offsets);
            const all_v: [4][]const i32 = .{ &.{}, &.{ 1, 2, 3 }, &.{ -1, 0, 1, 2 }, &.{ 0, 1, 2, 3, 4, 5, 6 } };
            const all_w: [4][]const f32 = .{ &.{}, &.{ 0.25, 0.5, 0.75 }, &.{ 1, 2, 3, 4 }, &.{ 0.125, -0.25 } };
            try std.testing.expectEqualSlices(i32, all_v[p], v);
            try std.testing.expectEqualSlices(f32, all_w[p], w);
        },
        .empty => {
            try std.testing.expectEqual(@as(usize, 0), batch.columnCount());
        },
        .sequence => {
            const ids = try batch.typedColumn(u32, 0);
            const negatives = try batch.typedColumn(i32, 1);
            const buckets = try batch.typedColumn(u16, 2);
            try std.testing.expectEqual(count, ids.len);
            try std.testing.expectEqual(count, negatives.len);
            try std.testing.expectEqual(count, buckets.len);
            for (0..count) |i| {
                const index: usize = @as(usize, @intCast(info.first_record)) + i;
                const signed: i32 = @intCast(index);
                try std.testing.expectEqual(@as(u32, @intCast(index)), ids[i]);
                try std.testing.expectEqual(-signed, negatives[i]);
                try std.testing.expectEqual(@as(u16, @intCast(index % 65536)), buckets[i]);
            }
        },
    }
}

/// Verify every decoded record, every sequence and record range, the complete
/// record count, and parser budget. The source consumes only a small header
/// allocation plus a fixed reader buffer, even for millions of rows.
pub fn run(a: std.mem.Allocator, io: std.Io, kind: Kind, record_count: usize) !void {
    // The generated index and its negation use canonical PLY u32/i32 types.
    if (kind == .sequence) try std.testing.expect(record_count <= @as(usize, std.math.maxInt(i32)));
    const s = spec(kind);
    const header = try a.print(
        "ply\nformat ascii 1.0\nelement {s} {d}\n{s}end_header\n",
        .{ s.name, record_count, s.properties });
    defer a.free(header);

    var synthetic = VirtualReader{
        .header = header,
        .rows = s.rows,
        .record_count = record_count,
        .unique_rows = kind == .sequence,
    };
    const memory_limit: usize = 1024 * 1024;
    var parser = try z.Parser.init(a, io, synthetic.reader(), .{
        .chunk_size = 16 * 1024,
        .memory_budget = memory_limit,
        .preserve_order = true,
    });
    defer parser.deinit();

    var consumed: usize = 0;
    var sequence: u64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        errdefer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(usize, 0), info.element_index);
        try std.testing.expectEqual(@as(u64, @intCast(consumed)), info.first_record);
        try std.testing.expectEqual(sequence, info.sequence);
        try std.testing.expect(info.record_count > 0);
        try std.testing.expect(info.record_count <= record_count - consumed);
        try verifyBatch(kind, &batch);
        consumed += info.record_count;
        sequence += 1;
        batch.release();
    }
    try std.testing.expectEqual(record_count, consumed);
    try std.testing.expect(synthetic.record_index == record_count);
    try std.testing.expectEqual(@as(usize, 0), synthetic.record_pos);
    const stats = parser.memoryStats();
    try std.testing.expect(stats.peak_total_bytes <= memory_limit);
    try std.testing.expect(stats.live_bytes <= memory_limit);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
}
