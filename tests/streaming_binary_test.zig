//! End-to-end streaming decode tests (Tasks 4.18, 4.14): the full
//! Reader → Parser → chunk planner → raw buffer → Phase 3 decoder
//! pipeline over deterministic binary fixtures of varied widths,
//! endianness, and element counts, plus trailing-data semantics.
//!
//! Fixtures:
//!   A — small XYZ, chunk size forcing several chunks
//!   B — XYZRGB (mixed widths), chunk size not a multiple of the width
//!   C — multiple elements with different widths and counts
//!   D — big-endian variants of A and B

const std = @import("std");
const support = @import("streaming_support.zig");

const internals = support.internals;
const Parser = support.Parser;
const Options = support.Options;
const decode = support.decode;

/// Concatenates a comptime header and a runtime body into one buffer.
fn makeFullPly(
    allocator: std.mem.Allocator,
    header_text: []const u8,
    body: []const u8,
) ![]u8 {
    const full = try allocator.alloc(u8, header_text.len + body.len);
    @memcpy(full[0..header_text.len], header_text);
    @memcpy(full[header_text.len..], body);
    return full;
}

/// Writes `count` XYZRGB records (three `T` coords, three u8 channels):
/// x = i, y = 2i, z = -i, r = 7i, g = 13i, b = 29i (mod 256).
fn writeXyzrgbBody(comptime T: type, endian: std.builtin.Endian, count: u64, out: []u8) void {
    const width = 3 * @sizeOf(T) + 3;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const record = out[@intCast(i * width)..][0..width];
        const expected = support.expectedXyz(T, i);
        support.writeScalar(T, endian, expected[0], record[0..@sizeOf(T)]);
        support.writeScalar(T, endian, expected[1], record[@sizeOf(T)..][0..@sizeOf(T)]);
        support.writeScalar(T, endian, expected[2], record[2 * @sizeOf(T) ..][0..@sizeOf(T)]);
        record[3 * @sizeOf(T)] = @truncate(i * 7);
        record[3 * @sizeOf(T) + 1] = @truncate(i * 13);
        record[3 * @sizeOf(T) + 2] = @truncate(i * 29);
    }
}

/// Asserts a decoded XYZRGB record against the fixture generator above.
fn expectXyzrgbRecord(comptime T: type, record_index: u64, view: decode.RecordView) !void {
    var values: [6]decode.ScalarValue = undefined;
    try view.decodeAll(&values);
    const expected = support.expectedXyz(T, record_index);
    try std.testing.expectEqual(expected[0], values[0].f32);
    try std.testing.expectEqual(expected[1], values[1].f32);
    try std.testing.expectEqual(expected[2], values[2].f32);
    try std.testing.expectEqual(@as(u8, @truncate(record_index * 7)), values[3].u8);
    try std.testing.expectEqual(@as(u8, @truncate(record_index * 13)), values[4].u8);
    try std.testing.expectEqual(@as(u8, @truncate(record_index * 29)), values[5].u8);
}

// --- Fixture A: small XYZ, several forced chunks ------------------------------

test "fixture A: 10 XYZ records stream in several chunks with exact values" {
    const header_text =
        "ply\nformat binary_little_endian 1.0\nelement vertex 10\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    var body: [10 * 12]u8 = undefined;
    support.writeXyzBody(f32, .little, 10, &body);
    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var options = Options{};
    options.chunk_size = 33; // floor(33/12) = 2 records per chunk
    parser.options = options;

    var stats = support.StreamStats{};
    // verifyXyzStream asserts every record's exact coordinates.
    try support.verifyXyzStream(f32, &parser, &stats, 10);

    try std.testing.expectEqual(@as(u64, 5), stats.chunks);
    try std.testing.expectEqual(@as(u64, 120), stats.body_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.last_element.?);
}

// --- Fixture B: mixed widths, chunk not a multiple of the width ---------------

test "fixture B: XYZRGB boundaries never shift colors between records" {
    const header_text =
        "ply\nformat binary_little_endian 1.0\nelement vertex 100\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n";
    var body: [100 * 15]u8 = undefined;
    writeXyzrgbBody(f32, .little, 100, &body);
    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    // 32 is not a multiple of 15: 2 records/chunk, and record boundaries
    // never align with chunk boundaries at the byte level.
    var options = Options{};
    options.chunk_size = 32;
    parser.options = options;

    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, {}, struct {
        fn visit(_: void, _: usize, record_index: u64, view: decode.RecordView) anyerror!void {
            try expectXyzrgbRecord(f32, record_index, view);
        }
    }.visit);

    try std.testing.expectEqual(@as(u64, 100), stats.records);
    try std.testing.expectEqual(@as(u64, 100 * 15), stats.body_bytes);
    try std.testing.expectEqual(@as(u64, 50), stats.chunks);
}

// --- Fixture C: multiple elements ----------------------------------------------

test "fixture C: several elements stream in declared order with correct values" {
    const header_text =
        "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 7\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "element camera 2\n" ++
        "property double px\nproperty double py\n" ++
        "element sample 3\n" ++
        "property ushort value\n" ++
        "end_header\n";

    // vertex: 7 × 12 B, camera: 2 × 16 B, sample: 3 × 2 B = 122 bytes.
    var body: [122]u8 = undefined;
    support.writeXyzBody(f32, .little, 7, body[0..84]);
    for (0..2) |i| {
        const record = body[84 + i * 16 ..][0..16];
        const px: f64 = @floatFromInt(i);
        const py: f64 = @floatFromInt(100 + i);
        support.writeScalar(f64, .little, px, record[0..8]);
        support.writeScalar(f64, .little, py, record[8..16]);
    }
    for (0..3) |i| {
        support.writeScalar(u16, .little, @intCast(i * 3), body[116 + i * 2 ..][0..2]);
    }

    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var options = Options{};
    options.chunk_size = 20; // 1 vertex record, 1 camera record, 10 samples per chunk
    parser.options = options;

    const Ctx = struct {
        vertex_records: u64 = 0,
        camera_records: u64 = 0,
        sample_records: u64 = 0,

        fn visit(self: *@This(), element_index: usize, record_index: u64, view: decode.RecordView) anyerror!void {
            switch (element_index) {
                0 => {
                    self.vertex_records += 1;
                    try support.expectXyzRecord(f32, record_index, view);
                },
                1 => {
                    self.camera_records += 1;
                    var values: [2]decode.ScalarValue = undefined;
                    try view.decodeAll(&values);
                    try std.testing.expectEqual(@as(f64, @floatFromInt(record_index)), values[0].f64);
                    try std.testing.expectEqual(@as(f64, @floatFromInt(100 + record_index)), values[1].f64);
                },
                2 => {
                    self.sample_records += 1;
                    var values: [1]decode.ScalarValue = undefined;
                    try view.decodeAll(&values);
                    try std.testing.expectEqual(@as(u16, @truncate(record_index * 3)), values[0].u16);
                },
                else => return error.UnexpectedElement,
            }
        }
    };
    var ctx: Ctx = .{};
    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, &ctx, Ctx.visit);

    try std.testing.expectEqual(@as(u64, 7), ctx.vertex_records);
    try std.testing.expectEqual(@as(u64, 2), ctx.camera_records);
    try std.testing.expectEqual(@as(u64, 3), ctx.sample_records);
    try std.testing.expectEqual(@as(u64, 122), stats.body_bytes);
    // Elements visited in header order; the last chunk belongs to `sample`.
    try std.testing.expectEqual(@as(?usize, 2), stats.last_element);
}

// --- Fixture D: big-endian variants ---------------------------------------------

test "fixture D: big-endian XYZ and XYZRGB decode identically in structure" {
    // Big-endian XYZ: the producer is unchanged; only the decoder's
    // byte order differs.
    {
        const header_text =
            "ply\nformat binary_big_endian 1.0\nelement vertex 10\n" ++
            "property float x\nproperty float y\nproperty float z\nend_header\n";
        var body: [10 * 12]u8 = undefined;
        support.writeXyzBody(f32, .big, 10, &body);
        const full = try makeFullPly(std.testing.allocator, header_text, &body);
        defer std.testing.allocator.free(full);

        var reader: std.Io.Reader = .fixed(full);
        var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
        defer parser.deinit();

        var options = Options{};
        options.chunk_size = 33;
        parser.options = options;

        var stats = support.StreamStats{};
        try support.verifyXyzStream(f32, &parser, &stats, 10);
        try std.testing.expectEqual(@as(u64, 5), stats.chunks);
    }

    // Big-endian XYZRGB with a chunk size forcing 1 record per chunk
    // (17 / 15 = 1 complete record).
    {
        const header_text =
            "ply\nformat binary_big_endian 1.0\nelement vertex 40\n" ++
            "property float x\nproperty float y\nproperty float z\n" ++
            "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n";
        var body: [40 * 15]u8 = undefined;
        writeXyzrgbBody(f32, .big, 40, &body);
        const full = try makeFullPly(std.testing.allocator, header_text, &body);
        defer std.testing.allocator.free(full);

        var reader: std.Io.Reader = .fixed(full);
        var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
        defer parser.deinit();

        var options = Options{};
        options.chunk_size = 17;
        parser.options = options;

        var stats = support.StreamStats{};
        try support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, _: usize, record_index: u64, view: decode.RecordView) anyerror!void {
                try expectXyzrgbRecord(f32, record_index, view);
            }
        }.visit);

        try std.testing.expectEqual(@as(u64, 40), stats.records);
        try std.testing.expectEqual(@as(u64, 40), stats.chunks);
    }
}

// --- Trailing data ---------------------------------------------------------------

test "trailing bytes after the declared body are left unread" {
    const header_text =
        "ply\nformat binary_little_endian 1.0\nelement vertex 4\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    var body_and_tail: [4 * 12 + 5]u8 = undefined;
    support.writeXyzBody(f32, .little, 4, body_and_tail[0..48]);
    for (body_and_tail[48..]) |*byte| byte.* = 0xFF; // trailing junk

    const full = try makeFullPly(std.testing.allocator, header_text, &body_and_tail);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.verifyXyzStream(f32, &parser, &stats, 4);

    // Completion is declared by record counts: the 5 trailing bytes were
    // never consumed. The fixed reader's logical position is at the end
    // of the declared body (header consumed by init, then 48 body bytes).
    const consumed = reader.seek;
    try std.testing.expectEqual(header_text.len + 4 * 12, consumed);
}
