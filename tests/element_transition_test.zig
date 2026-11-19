//! Element transition tests (Task 4.15): declared-order traversal across
//! multiple fixed-width elements, zero-count elements (with and without
//! list properties), record-index restarts, sequence continuity, and the
//! unsupported variable-length boundary.

const std = @import("std");
const support = @import("streaming_support.zig");

const internals = support.internals;
const Parser = support.Parser;
const Options = support.Options;
const decode = support.decode;

/// Builds `header_text ++ body` in one allocation.
fn makeFullPly(allocator: std.mem.Allocator, header_text: []const u8, body: []const u8) ![]u8 {
    const full = try allocator.alloc(u8, header_text.len + body.len);
    @memcpy(full[0..header_text.len], header_text);
    @memcpy(full[header_text.len..], body);
    return full;
}

test "element transitions follow the header exactly" {
    // vertex 5 × 12 B, empty 0, camera 2 × 16 B, sample 3 × 2 B.
    const header_text =
        "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 5\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "element empty 0\n" ++
        "property uchar flag\n" ++
        "element camera 2\n" ++
        "property double x\nproperty double y\n" ++
        "element sample 3\n" ++
        "property ushort value\n" ++
        "end_header\n";

    var body: [5 * 12 + 2 * 16 + 3 * 2]u8 = undefined;
    support.writeXyzBody(f32, .little, 5, body[0..60]);
    for (0..2) |i| {
        const record = body[60 + i * 16 ..][0..16];
        support.writeScalar(f64, .little, @floatFromInt(i * 10), record[0..8]);
        support.writeScalar(f64, .little, @floatFromInt(i * 20), record[8..16]);
    }
    for (0..3) |i| {
        support.writeScalar(u16, .little, @intCast(100 + i), body[92 + i * 2 ..][0..2]);
    }

    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var options = Options{};
    options.chunk_size = 24; // 2 vertex records / 1 camera record / 12 samples
    parser.options = options;

    // The zero-count `empty` element must appear in the header schema...
    const layouts = parser.layouts();
    try std.testing.expectEqual(@as(usize, 4), layouts.len);
    try std.testing.expectEqual(@as(u64, 0), parser.header().elements[1].count);

    const Ctx = struct {
        records_seen: [4]u64 = .{ 0, 0, 0, 0 },

        fn visit(self: *@This(), element_index: usize, record_index: u64, view: decode.RecordView) anyerror!void {
            self.records_seen[element_index] += 1;
            switch (element_index) {
                0 => try support.expectXyzRecord(f32, record_index, view),
                1 => return error.UnexpectedElement, // zero-count: never visited
                2 => {
                    var values: [2]decode.ScalarValue = undefined;
                    try view.decodeAll(&values);
                    try std.testing.expectEqual(@as(f64, @floatFromInt(record_index * 10)), values[0].f64);
                    try std.testing.expectEqual(@as(f64, @floatFromInt(record_index * 20)), values[1].f64);
                },
                3 => {
                    var values: [1]decode.ScalarValue = undefined;
                    try view.decodeAll(&values);
                    try std.testing.expectEqual(@as(u16, @truncate(100 + record_index)), values[0].u16);
                },
                else => return error.UnexpectedElement,
            }
        }
    };
    var ctx: Ctx = .{};
    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, &ctx, Ctx.visit);

    // Exactly the declared records, each visited once.
    try std.testing.expectEqual(@as(u64, 5), ctx.records_seen[0]);
    try std.testing.expectEqual(@as(u64, 0), ctx.records_seen[1]);
    try std.testing.expectEqual(@as(u64, 2), ctx.records_seen[2]);
    try std.testing.expectEqual(@as(u64, 3), ctx.records_seen[3]);

    // No bytes were consumed for the zero-count element; the total equals
    // the sum of the supported element body sizes.
    try std.testing.expectEqual(@as(u64, 60 + 32 + 6), stats.body_bytes);

    // Record numbering restarted per element (asserted by the harness)
    // and the sequence continued monotonically across all elements.
    const expected_chunks = 3 + 2 + 1; // vertex, camera, sample batches
    try std.testing.expectEqual(@as(u64, expected_chunks), stats.chunks);
    try std.testing.expectEqual(@as(?usize, 3), stats.last_element);
    try std.testing.expectEqual(@as(u64, 3), stats.last_element_end);
}

test "a zero-count element with list properties is skipped without error" {
    // `face 0` declares a list property but owns no records: advancing
    // past it needs no list decoding and consumes no bytes.
    const header_text =
        "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 2\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "element face 0\n" ++
        "property list uchar int vertex_indices\n" ++
        "element marker 1\n" ++
        "property uchar flag\n" ++
        "end_header\n";

    var body: [2 * 12 + 1]u8 = @splat(0);
    support.writeXyzBody(f32, .little, 2, body[0..24]);

    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, {}, struct {
        fn visit(_: void, element_index: usize, record_index: u64, view: decode.RecordView) anyerror!void {
            // Only vertex (record 0/1) and marker (record 0) are visited.
            if (element_index == 0) {
                try support.expectXyzRecord(f32, record_index, view);
            } else {
                try std.testing.expectEqual(@as(usize, 2), element_index);
                try std.testing.expectEqual(@as(u64, 0), record_index);
            }
        }
    }.visit);

    try std.testing.expectEqual(@as(u64, 25), stats.body_bytes);
    // Default 4 MiB chunks: one vertex chunk, one zero-width marker chunk.
    // The sequence continued monotonically across the skipped `face`.
    try std.testing.expectEqual(@as(u64, 2), stats.chunks);
    try std.testing.expectEqual(@as(?usize, 2), stats.last_element);
}

test "a nonempty variable-length element stops traversal at its position" {
    // vertex 3, then a nonempty `face` element with a list property, then
    // a trailing fixed-width element. The producer must stop at `face`
    // and never reach the trailing element.
    const header_text =
        "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 3\n" ++
        "property float x\nproperty float y\nproperty float z\n" ++
        "element face 2\n" ++
        "property list uchar int vertex_indices\n" ++
        "element after 4\n" ++
        "property uchar flag\n" ++
        "end_header\n";

    // Vertex records followed by what would be the trailing element's
    // body: the producer must never read the `after` bytes.
    var body: [3 * 12 + 4]u8 = undefined;
    support.writeXyzBody(f32, .little, 3, body[0..36]);
    for (body[36..]) |*byte| byte.* = 0xEE;

    const full = try makeFullPly(std.testing.allocator, header_text, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var stats = support.StreamStats{};
    try std.testing.expectError(
        error.UnsupportedVariableLengthElement,
        support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, element_index: usize, record_index: u64, view: decode.RecordView) anyerror!void {
                try std.testing.expectEqual(@as(usize, 0), element_index);
                try support.expectXyzRecord(f32, record_index, view);
            }
        }.visit),
    );

    // The vertex chunks were emitted and are valid; the producer stopped
    // at the face element without jumping ahead.
    try std.testing.expectEqual(@as(u64, 3), stats.records);
    try std.testing.expectEqual(@as(u64, 36), stats.body_bytes);
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .failed), parser.state);
    try std.testing.expectEqual(@as(usize, 1), parser.producer.element_index);

    // Terminal: no restart, no jump to the trailing element.
    try std.testing.expectError(
        error.InvalidProducerState,
        internals.parser.nextRawChunkForTesting(&parser),
    );
}
