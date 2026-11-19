//! Reader boundary tests (Task 4.14): the implementation must rely
//! exclusively on the `std.Io.Reader` contract. Every reader double and
//! fragmentation pattern must produce identical parsing results, and
//! underlying read sizes are never assumed to relate to record sizes.

const std = @import("std");
const support = @import("streaming_support.zig");

const internals = support.internals;
const Parser = support.Parser;
const Options = support.Options;
const decode = support.decode;

const xyzrgb_header =
    "ply\nformat binary_little_endian 1.0\nelement vertex 97\n" ++
    "property float x\nproperty float y\nproperty float z\n" ++
    "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n";

fn makeFullPly(allocator: std.mem.Allocator, header_text: []const u8, body: []const u8) ![]u8 {
    const full = try allocator.alloc(u8, header_text.len + body.len);
    @memcpy(full[0..header_text.len], header_text);
    @memcpy(full[header_text.len..], body);
    return full;
}

/// Streams the fixture through a parser built over `reader_source` with
/// the given reader wrapper behavior, returning the resulting stats.
fn runFixture(
    source: []const u8,
    options: Options,
) !support.StreamStats {
    var reader: std.Io.Reader = .fixed(source);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, {}, struct {
        fn visit(_: void, _: usize, record_index: u64, view: decode.RecordView) anyerror!void {
            var values: [6]decode.ScalarValue = undefined;
            try view.decodeAll(&values);
            const expected = support.expectedXyz(f32, record_index);
            try std.testing.expectEqual(expected[0], values[0].f32);
            try std.testing.expectEqual(expected[1], values[1].f32);
            try std.testing.expectEqual(expected[2], values[2].f32);
            try std.testing.expectEqual(@as(u8, @truncate(record_index * 7)), values[3].u8);
            try std.testing.expectEqual(@as(u8, @truncate(record_index * 13)), values[4].u8);
            try std.testing.expectEqual(@as(u8, @truncate(record_index * 29)), values[5].u8);
        }
    }.visit);
    return stats;
}

test "every fragmentation pattern produces identical results" {
    var body: [97 * 15]u8 = undefined;
    // XYZRGB coords: x=i, y=2i, z=-i; channels 7i/13i/29i mod 256.
    const width = 15;
    var i: u64 = 0;
    while (i < 97) : (i += 1) {
        const record = body[@intCast(i * width)..][0..width];
        const expected = support.expectedXyz(f32, i);
        support.writeScalar(f32, .little, expected[0], record[0..4]);
        support.writeScalar(f32, .little, expected[1], record[4..8]);
        support.writeScalar(f32, .little, expected[2], record[8..12]);
        record[12] = @truncate(i * 7);
        record[13] = @truncate(i * 13);
        record[14] = @truncate(i * 29);
    }
    const full = try makeFullPly(std.testing.allocator, xyzrgb_header, &body);
    defer std.testing.allocator.free(full);

    var options = Options{};
    options.chunk_size = 37; // floor(37/15)=2 records per chunk

    const baseline = try runFixture(full, options);
    try std.testing.expectEqual(@as(u64, 97), baseline.records);
    try std.testing.expectEqual(@as(u64, 97 * 15), baseline.body_bytes);

    // Fragmentation patterns from the spec, plus extremes: byte-at-a-time
    // delivery, large fragments straddling record boundaries, and
    // irregular mixed sizes. Record width is 15 — none of the pattern
    // totals align with it deliberately.
    const patterns = [_][]const usize{
        &.{1},
        &.{ 2, 3, 5, 7 },
        &.{ 64, 1, 128, 3 },
        &.{5},
        &.{ 14, 16 },
        &.{15},
        &.{1000},
    };
    for (patterns) |pattern| {
        var frag = support.FragmentingReader.init(full, pattern, 0);
        var parser = try Parser.init(
            std.testing.allocator,
            std.testing.io,
            frag.reader(),
            options,
        );
        defer parser.deinit();

        var stats = support.StreamStats{};
        try support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, _: usize, record_index: u64, view: decode.RecordView) anyerror!void {
                var values: [6]decode.ScalarValue = undefined;
                try view.decodeAll(&values);
                const expected = support.expectedXyz(f32, record_index);
                try std.testing.expectEqual(expected[0], values[0].f32);
                try std.testing.expectEqual(expected[1], values[1].f32);
                try std.testing.expectEqual(expected[2], values[2].f32);
                try std.testing.expectEqual(@as(u8, @truncate(record_index * 7)), values[3].u8);
                try std.testing.expectEqual(@as(u8, @truncate(record_index * 13)), values[4].u8);
                try std.testing.expectEqual(@as(u8, @truncate(record_index * 29)), values[5].u8);
            }
        }.visit);

        // Identical chunk structure, record accounting, and checksum:
        // the fragmentation is invisible above the Reader contract.
        try std.testing.expectEqual(baseline.chunks, stats.chunks);
        try std.testing.expectEqual(baseline.records, stats.records);
        try std.testing.expectEqual(baseline.body_bytes, stats.body_bytes);
        try std.testing.expectEqual(baseline.hash, stats.hash);
    }
}

test "a reader composited after a consumed prefix parses the same body" {
    // A non-seekable composite: something before the PLY data has already
    // been consumed. The parser sees a reader positioned at the PLY start.
    const prefix = "NOT-A-PLY-HEADER-JUST-AN-UPSTREAM-PREFIX\n";
    const header_text =
        "ply\nformat binary_little_endian 1.0\nelement vertex 6\n" ++
        "property float x\nproperty float y\nproperty float z\nend_header\n";
    var body: [6 * 12]u8 = undefined;
    support.writeXyzBody(f32, .little, 6, &body);

    var full: [prefix.len + header_text.len + 6 * 12]u8 = undefined;
    @memcpy(full[0..prefix.len], prefix);
    @memcpy(full[prefix.len..][0..header_text.len], header_text);
    support.writeXyzBody(f32, .little, 6, full[prefix.len + header_text.len ..]);

    var options = Options{};
    options.chunk_size = 12;

    var frag = support.FragmentingReader.init(&full, &.{ 4, 2, 9 }, prefix.len);
    var parser = try Parser.init(
        std.testing.allocator,
        std.testing.io,
        frag.reader(),
        options,
    );
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.verifyXyzStream(f32, &parser, &stats, 6);
    try std.testing.expectEqual(@as(u64, 6), stats.chunks);
}

test "zero-width elements never depend on reader behavior" {
    const marker_header =
        "ply\nformat binary_little_endian 1.0\nelement marker 300000\nend_header\n";
    // The header parses normally; any attempted *body* read fails
    // immediately (fail_after == header length). Zero-width records must
    // never trigger it.
    var failing = support.FailingReader.init(marker_header, marker_header.len);

    var parser = try Parser.init(
        std.testing.allocator,
        std.testing.io,
        failing.reader(),
        .{},
    );
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, {}, struct {
        fn visit(_: void, _: usize, _: u64, _: decode.RecordView) anyerror!void {
            return;
        }
    }.visit);

    // 300000 = 4 × 65536 + 37760: five bounded logical chunks, zero bytes.
    try std.testing.expectEqual(@as(u64, 5), stats.chunks);
    try std.testing.expectEqual(@as(u64, 300000), stats.records);
    try std.testing.expectEqual(@as(u64, 0), stats.body_bytes);
}

test "byte-at-a-time delivery through a tiny-chunk parser stays record-safe" {
    const header_text =
        "ply\nformat binary_little_endian 1.0\nelement vertex 9\n" ++
        "property double px\nproperty double py\nproperty double pz\nend_header\n";
    var body: [9 * 24]u8 = undefined;
    support.writeXyzBody(f64, .little, 9, &body);
    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var options = Options{};
    options.chunk_size = 10; // floor(10/24) = 1 record per chunk

    var frag = support.FragmentingReader.init(full, &.{1}, 0);
    var parser = try Parser.init(
        std.testing.allocator,
        std.testing.io,
        frag.reader(),
        options,
    );
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.verifyXyzStream(f64, &parser, &stats, 9);
    try std.testing.expectEqual(@as(u64, 9), stats.chunks);
    try std.testing.expectEqual(@as(u64, 9 * 24), stats.body_bytes);
}
