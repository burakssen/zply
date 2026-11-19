//! Large-stream memory tests (Task 4.18 fixture E): 3,000,000 f64 XYZ
//! records (72 MB body) streamed through a small reusable raw buffer,
//! verifying bounded memory, deterministic values, and successful
//! completion — plus a leak-free full run under a testing allocator.

const std = @import("std");
const support = @import("streaming_support.zig");

const internals = support.internals;
const Parser = support.Parser;
const Options = support.Options;

const record_count: u64 = 3_000_000;
const record_width: usize = 3 * @sizeOf(f64); // 24 B
const body_bytes: u64 = record_count * record_width; // 72,000,000

const header_text =
    "ply\nformat binary_little_endian 1.0\nelement vertex 3000000\n" ++
    "property double x\nproperty double y\nproperty double z\nend_header\n";

/// Runs the full 72 MB body through the parser at the given chunk size,
/// asserting bounded raw-buffer memory and exact values throughout.
fn runLargeStream(chunk_size: usize) !void {
    // Build the deterministic fixture once per run (x = i, y = 2i, z = -i).
    const full = try std.testing.allocator.alloc(u8, header_text.len + @as(usize, @intCast(body_bytes)));
    defer std.testing.allocator.free(full);
    @memcpy(full[0..header_text.len], header_text);
    support.writeXyzBody(f64, .little, record_count, full[header_text.len..]);

    var reader: std.Io.Reader = .fixed(full);
    var options = Options{};
    options.chunk_size = chunk_size;
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();

    // The loop below is the acceptance criteria of fixture E.
    var stats = support.StreamStats{};
    var last_capacity: usize = 0;

    // Manual streaming loop (instead of the all-in-one harness) so the
    // raw buffer's capacity can be sampled during steady state.
    const layouts = parser.layouts();
    const header = parser.header();
    const fixed = try internals.decode.FixedLayout.initForEncoding(&layouts[0], header.encoding);

    var records_seen: u64 = 0;
    var next_sequence: u64 = 0;
    while (try internals.parser.nextRawChunkForTesting(&parser)) |chunk| {
        try std.testing.expectEqual(next_sequence, chunk.sequence);
        next_sequence += 1;
        try std.testing.expectEqual(@as(usize, 0), chunk.element_index);
        try std.testing.expectEqual(records_seen, chunk.first_record);
        records_seen += chunk.record_count;

        // Exact coordinates for the first and last record of the chunk
        // (sampled assertions) — no reordering can slip through.
        try support.expectXyzRecord(f64, chunk.first_record, try internals.decode.RecordView.init(fixed, chunk.bytes[0..record_width]));
        const last_index: u64 = chunk.first_record + chunk.record_count - 1;
        try support.expectXyzRecord(
            f64,
            last_index,
            try internals.decode.RecordView.init(fixed, chunk.bytes[chunk.bytes.len - record_width ..]),
        );

        // All records of the chunk decode to the deterministic values,
        // folded into the sequence-aware checksum.
        const Ctx = struct { stats: *support.StreamStats, first: u64 };
        var ctx: Ctx = .{ .stats = &stats, .first = chunk.first_record };
        try internals.decode.decodeRange(fixed, chunk.bytes, chunk.record_count, &ctx, struct {
            fn visit(c: *Ctx, local_index: u64, view: internals.decode.RecordView) anyerror!void {
                const record_index = c.first + local_index;
                var values: [3]internals.decode.ScalarValue = undefined;
                try view.decodeAll(&values);
                const expected = support.expectedXyz(f64, record_index);
                try std.testing.expectEqual(expected[0], values[0].f64);
                try std.testing.expectEqual(expected[1], values[1].f64);
                try std.testing.expectEqual(expected[2], values[2].f64);
                c.stats.hash ^= record_index ^ std.hash.Wyhash.hash(c.stats.hash, view.bytes);
            }
        }.visit);
        stats.body_bytes += chunk.bytes.len;

        // Bounded memory: the raw buffer never grows past the chunk size
        // (plus at most the alignment headroom of one record boundary),
        // and it is allocated once — capacity never changes after the
        // first chunk.
        const capacity = parser.raw_buffer.capacity();
        try std.testing.expect(capacity <= chunk_size);
        if (last_capacity != 0) {
            try std.testing.expectEqual(last_capacity, capacity);
        }
        last_capacity = capacity;
    }

    try std.testing.expectEqual(record_count, records_seen);
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .completed), parser.state);
    // The whole body was consumed exactly; trailing bytes would remain
    // unread (none exist here).
    try std.testing.expectEqual(@as(u64, body_bytes), stats.body_bytes);
    try std.testing.expectEqual(@as(u64, 0), parser.producer.next_record);
}

test "fixture E: 3M f64 records stream with a 1 MiB buffer" {
    try runLargeStream(1024 * 1024);
}

test "fixture E: 3M f64 records stream with a 64 KiB buffer" {
    // Small chunks: ~1122 chunks over the 72 MB body — the record loop
    // overhead stays proportional to chunk count, never to record count.
    try runLargeStream(64 * 1024);
}
