//! Producer-level streaming tests (Tasks 4.5–4.10, 4.17): fragmentation
//! independence, two-step plan/read with capacity fitting, counter
//! bookkeeping, composable mid-stream readers, transactional behavior
//! across elements, zero-width progression, and plan validation.
//!
//! These drive `input.Producer` directly (no `Parser`); parser-level
//! behavior lives in the other Phase 4 suites. Uses the internals universe.

const std = @import("std");
const support = @import("streaming_support.zig");
const decode_support = @import("decode_support.zig");

const internals = support.internals;
const input = internals.input;
const Producer = input.Producer;
const Options = internals.options.Options;
const parseHeader = decode_support.parseHeader;

const xyz3_header =
    "ply\nformat binary_little_endian 1.0\nelement vertex 3\n" ++
    "property float x\nproperty float y\nproperty float z\nend_header\n";

const two_element_header =
    "ply\nformat binary_little_endian 1.0\nelement vertex 2\n" ++
    "property float x\nproperty float y\n" ++
    "element camera 1\nproperty double px\nend_header\n";

const zero_width_header =
    "ply\nformat binary_little_endian 1.0\nelement marker 200000\nend_header\n";

/// Serialized snapshot of one chunk's metadata (the borrowed bytes are
/// compared through the decoded record values).
const ChunkMeta = struct {
    element_index: usize,
    first_record: u64,
    record_count: u64,
    sequence: u64,
    byte_offset: u64,
    byte_len: usize,
};

const Run = struct {
    metas: std.ArrayList(ChunkMeta),
    /// Flattened decoded `property float x/y/z` values per record.
    values: std.ArrayList(f32),
};

fn collectXyzRun(
    producer: *Producer,
    reader: *std.Io.Reader,
    header: *const internals.header.Header,
    layouts: []const internals.layout.ElementLayout,
    options: Options,
    destination: []u8,
    run: *Run,
) !void {
    const fixed = try internals.decode.FixedLayout.initForEncoding(
        &layouts[0],
        header.encoding,
    );

    while (try producer.nextInto(reader, header, layouts, destination, options)) |chunk| {
        try chunk.validateAgainstWidth(layouts[chunk.element_index].fixed_record_size.?);
        try run.metas.append(std.testing.allocator, .{
            .element_index = chunk.element_index,
            .first_record = chunk.first_record,
            .record_count = chunk.record_count,
            .sequence = chunk.sequence,
            .byte_offset = chunk.byte_offset,
            .byte_len = chunk.bytes.len,
        });
        try internals.decode.decodeRange(fixed, chunk.bytes, chunk.record_count, run, struct {
            fn visit(r: *Run, _: u64, view: internals.decode.RecordView) anyerror!void {
                var v: [3]internals.decode.ScalarValue = undefined;
                try view.decodeAll(&v);
                try r.values.append(std.testing.allocator, v[0].f32);
                try r.values.append(std.testing.allocator, v[1].f32);
                try r.values.append(std.testing.allocator, v[2].f32);
            }
        }.visit);
    }
}

test "fragmented delivery produces identical chunks and values to a fixed reader" {
    var body: [3 * 12]u8 = undefined;
    support.writeXyzBody(f32, .little, 3, &body);

    const header_text = xyz3_header;
    var storage = try parseHeader(header_text);
    defer storage.deinit();

    const header = &storage.header;
    const layouts = storage.layouts;

    // Run 1: plain fixed reader.
    var fixed_reader: std.Io.Reader = .fixed(&body);
    var producer1 = Producer{};
    var options: Options = .{};
    options.chunk_size = 20; // floor(20/12)=1 record per chunk
    var run1: Run = .{
        .metas = .empty,
        .values = .empty,
    };
    defer {
        run1.metas.deinit(std.testing.allocator);
        run1.values.deinit(std.testing.allocator);
    }
    var destination: [64]u8 = undefined;
    try collectXyzRun(&producer1, &fixed_reader, header, layouts, options, &destination, &run1);

    // Run 2: heavily fragmented reader, unrelated to record boundaries.
    var frag = support.FragmentingReader.init(&body, &.{ 1, 2, 5, 7 }, 0);
    var producer2 = Producer{};
    var run2: Run = .{
        .metas = .empty,
        .values = .empty,
    };
    defer {
        run2.metas.deinit(std.testing.allocator);
        run2.values.deinit(std.testing.allocator);
    }
    try collectXyzRun(&producer2, frag.reader(), header, layouts, options, &destination, &run2);

    // Identical chunk structure and decoded values.
    try std.testing.expectEqual(run1.metas.items.len, run2.metas.items.len);
    for (run1.metas.items, run2.metas.items) |m1, m2| {
        try std.testing.expectEqual(m1.element_index, m2.element_index);
        try std.testing.expectEqual(m1.first_record, m2.first_record);
        try std.testing.expectEqual(m1.record_count, m2.record_count);
        try std.testing.expectEqual(m1.sequence, m2.sequence);
        try std.testing.expectEqual(m1.byte_offset, m2.byte_offset);
        try std.testing.expectEqual(m1.byte_len, m2.byte_len);
    }
    try std.testing.expectEqualSlices(f32, run1.values.items, run2.values.items);
    try std.testing.expectEqual(@as(usize, 3), run1.values.items.len / 3);

    // Expected values: x=i, y=2i, z=-i.
    for (0..3) |i| {
        const expected = support.expectedXyz(f32, @intCast(i));
        try std.testing.expectEqual(expected[0], run1.values.items[i * 3]);
        try std.testing.expectEqual(expected[1], run1.values.items[i * 3 + 1]);
        try std.testing.expectEqual(expected[2], run1.values.items[i * 3 + 2]);
    }
    try std.testing.expectEqual(Producer.State.completed, producer2.state);
}

test "two-step plan/read fits the plan to a smaller destination" {
    var body: [3 * 12]u8 = undefined;
    support.writeXyzBody(f32, .little, 3, &body);

    var storage = try parseHeader(xyz3_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    var reader: std.Io.Reader = .fixed(&body);
    var producer = Producer{};
    var options: Options = .{};
    options.chunk_size = 4096; // desired: all 3 records (36 bytes)
    var destination: [64]u8 = undefined;

    // Step 1: plan; step 2: the destination only fits two records.
    const desired = (try producer.planNext(header, layouts, options)).?;
    try std.testing.expectEqual(@as(u64, 3), desired.record_count);
    const fitted = try internals.input.planner.fitToCapacity(desired, 24);
    try std.testing.expectEqual(@as(u64, 2), fitted.record_count);
    try std.testing.expectEqual(@as(u64, 24), fitted.byte_count);

    const chunk1 = try producer.readPlanned(&reader, fitted, destination[0..24], 3);
    try std.testing.expectEqual(@as(u64, 0), chunk1.first_record);
    try std.testing.expectEqual(@as(u64, 2), chunk1.record_count);

    // The next plan continues from record 2 with one record remaining.
    const plan2 = (try producer.planNext(header, layouts, options)).?;
    try std.testing.expectEqual(@as(u64, 2), plan2.first_record);
    try std.testing.expectEqual(@as(u64, 1), plan2.record_count);
    const chunk2 = try producer.readPlanned(
        &reader,
        plan2,
        destination[0..@intCast(plan2.byte_count)],
        3,
    );
    try std.testing.expectEqual(@as(u64, 2), chunk2.first_record);
    try std.testing.expect((try producer.planNext(header, layouts, options)) == null);
    try std.testing.expectEqual(Producer.State.completed, producer.state);
}

test "counters and nextByteOffset track progress across chunks" {
    var body: [3 * 12]u8 = undefined;
    support.writeXyzBody(f32, .little, 3, &body);

    var storage = try parseHeader(xyz3_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    var reader: std.Io.Reader = .fixed(&body);
    var producer = Producer{};
    var options: Options = .{};
    options.chunk_size = 12; // one record per chunk

    var consumed: u64 = 0;
    var destination: [64]u8 = undefined;
    var sequence: u64 = 0;
    while (try producer.nextInto(&reader, header, layouts, &destination, options)) |chunk| {
        try std.testing.expectEqual(sequence, chunk.sequence);
        try std.testing.expectEqual(header.body_offset + consumed, chunk.byte_offset);
        consumed += chunk.bytes.len;
        try std.testing.expectEqual(header.body_offset + consumed, try producer.nextByteOffset(header));
        sequence += 1;
    }
    try std.testing.expectEqual(@as(u64, 0), producer.next_record);
    try std.testing.expectEqual(@as(u64, 36), producer.body_bytes_consumed);
    try std.testing.expectEqual(@as(u64, 3), producer.sequence);
    try std.testing.expectEqual(header.body_offset + 36, try producer.nextByteOffset(header));
}

test "a composited reader starting at a nonzero position works identically" {
    // The full PLY source: header consumed by the header parser, body read
    // from the same buffer — the producer's byte offsets are PLY-relative
    // regardless of the reader's absolute position.
    const header_len = xyz3_header.len;
    const full = try std.testing.allocator.alloc(u8, header_len + 3 * 12);
    defer std.testing.allocator.free(full);
    @memcpy(full[0..header_len], xyz3_header);
    support.writeXyzBody(f32, .little, 3, full[header_len..]);

    var storage = try parseHeader(xyz3_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    // A fragmenting reader positioned at the body start inside the full
    // buffer (nonzero absolute position).
    var frag = support.FragmentingReader.init(full, &.{ 3, 9 }, header_len);
    var producer = Producer{};
    var options: Options = .{};
    options.chunk_size = 24;

    var destination: [64]u8 = undefined;
    var records: u64 = 0;
    var offset = header.body_offset;
    while (try producer.nextInto(frag.reader(), header, layouts, &destination, options)) |chunk| {
        try std.testing.expectEqual(offset, chunk.byte_offset);
        offset += chunk.bytes.len;
        records += chunk.record_count;
    }
    try std.testing.expectEqual(@as(u64, 3), records);
    try std.testing.expectEqual(Producer.State.completed, producer.state);
}

test "earlier chunks stay valid when a later element is truncated" {
    // vertex 2 × 8 B then camera 1 × 8 B = 24 B body; truncate to 18 B.
    var body: [24]u8 = @splat(0);

    var storage = try parseHeader(two_element_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    var reader: std.Io.Reader = .fixed(body[0..18]);
    var producer = Producer{};
    var options: Options = .{};
    options.chunk_size = 64;

    var destination: [64]u8 = undefined;

    // The vertex chunk completes successfully and stays valid.
    const vertex_chunk = (try producer.nextInto(&reader, header, layouts, &destination, options)).?;
    try std.testing.expectEqual(@as(usize, 0), vertex_chunk.element_index);
    try std.testing.expectEqual(@as(u64, 2), vertex_chunk.record_count);

    // The camera element declares 8 bytes; only 2 remain.
    try std.testing.expectError(
        error.TruncatedBody,
        producer.nextInto(&reader, header, layouts, &destination, options),
    );

    // The failure is terminal; committed progress from the successful
    // chunk is preserved and no partial chunk was emitted.
    try std.testing.expectEqual(Producer.State.failed, producer.state);
    try std.testing.expectEqual(@as(usize, 1), producer.element_index);
    try std.testing.expectEqual(@as(u64, 0), producer.next_record);
    try std.testing.expectEqual(@as(u64, 16), producer.body_bytes_consumed);
    try std.testing.expectEqual(@as(u64, 1), producer.sequence);
    try std.testing.expectError(
        error.InvalidProducerState,
        producer.nextInto(&reader, header, layouts, &destination, options),
    );
}

test "zero-width records complete without ever touching the reader" {
    var storage = try parseHeader(zero_width_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    // A reader that fails on the very first read: if the producer ever
    // attempted an exact-length read for zero-width records, this would
    // fail. It must not touch the reader at all.
    var failing = support.FailingReader.init(&.{}, null);
    var producer = Producer{};
    const options: Options = .{};

    var destination: [8]u8 = undefined;
    var chunks: u64 = 0;
    var records: u64 = 0;
    while (try producer.nextInto(failing.reader(), header, layouts, &destination, options)) |chunk| {
        try std.testing.expectEqual(@as(usize, 0), chunk.bytes.len);
        try std.testing.expect(chunk.record_count > 0);
        // The byte offset stays unchanged: zero-width records own no bytes.
        try std.testing.expectEqual(header.body_offset, chunk.byte_offset);
        records += chunk.record_count;
        chunks += 1;
    }
    try std.testing.expectEqual(@as(u64, 200000), records);
    // 200000 = 3 × 65536 + 3392: four bounded logical chunks.
    try std.testing.expectEqual(@as(u64, 4), chunks);
    try std.testing.expectEqual(@as(u64, 0), producer.body_bytes_consumed);
    try std.testing.expectEqual(Producer.State.completed, producer.state);
}

test "an oversized record is one complete chunk per record" {
    const wide_header =
        "ply\nformat binary_little_endian 1.0\nelement blob 2\n" ++
        "property double p0\nproperty double p1\nproperty double p2\n" ++
        "property double p3\nproperty double p4\nproperty double p5\n" ++
        "property double p6\nproperty double p7\nproperty double p8\n" ++
        "property double p9\nend_header\n";
    var body: [2 * 80]u8 = @splat(0);

    var storage = try parseHeader(wide_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    var reader: std.Io.Reader = .fixed(&body);
    var producer = Producer{};
    var options: Options = .{};
    options.chunk_size = 64; // smaller than one 80-byte record

    var destination: [96]u8 = undefined;
    var first: ?u64 = null;
    var count: u64 = 0;
    while (try producer.nextInto(&reader, header, layouts, &destination, options)) |chunk| {
        // Never split: one whole record per chunk.
        try std.testing.expectEqual(@as(u64, 1), chunk.record_count);
        try std.testing.expectEqual(@as(usize, 80), chunk.bytes.len);
        if (first) |seen| {
            try std.testing.expectEqual(seen + 1, chunk.first_record);
        }
        first = chunk.first_record;
        count += 1;
    }
    try std.testing.expectEqual(@as(u64, 2), count);
    try std.testing.expectEqual(@as(u64, 160), producer.body_bytes_consumed);
}

test "readPlanned rejects a plan describing a different element count" {
    var body: [16]u8 = @splat(0);

    var storage = try parseHeader(two_element_header);
    defer storage.deinit();
    const header = &storage.header;
    const layouts = storage.layouts;

    var reader: std.Io.Reader = .fixed(&body);
    var producer = Producer{};
    var options: Options = .{};
    options.chunk_size = 64;

    var destination: [64]u8 = undefined;
    const plan = (try producer.planNext(header, layouts, options)).?;

    // A plan carrying the wrong declared element count is stale/forged.
    try std.testing.expectError(
        error.InvalidProducerState,
        producer.readPlanned(&reader, plan, &destination, 3),
    );
    // The producer did not commit or fail: the plan can still be read.
    const chunk = try producer.readPlanned(&reader, plan, &destination, 2);
    try std.testing.expectEqual(@as(u64, 2), chunk.record_count);
}
