//! Truncated, failing, and unsupported-body tests (Task 4.16): every
//! failure mode is reported explicitly, enters the terminal failed state,
//! commits no partial progress, and leaks nothing.

const std = @import("std");
const support = @import("streaming_support.zig");

const internals = support.internals;
const Parser = support.Parser;
const Options = support.Options;

const xyz_header =
    "ply\nformat binary_little_endian 1.0\nelement vertex 2\n" ++
    "property float x\nproperty float y\nproperty float z\nend_header\n";

const ascii_header =
    "ply\nformat ascii 1.0\nelement vertex 2\n" ++
    "property float x\nproperty float y\nproperty float z\nend_header\n";

const face_header =
    "ply\nformat binary_little_endian 1.0\n" ++
    "element vertex 1\nproperty float x\n" ++
    "element face 1\nproperty list uchar int vertex_indices\n" ++
    "end_header\n";

/// Builds `header_text ++ body_prefix` in one buffer.
fn makeFullPly(allocator: std.mem.Allocator, header_text: []const u8, body_prefix: []const u8) ![]u8 {
    const full = try allocator.alloc(u8, header_text.len + body_prefix.len);
    @memcpy(full[0..header_text.len], header_text);
    @memcpy(full[header_text.len..], body_prefix);
    return full;
}

/// A truncated body of `prefix_len` bytes for the 2-record XYZ fixture
/// (declared body: 24 bytes).
fn truncatedBody(comptime prefix_len: usize) [prefix_len]u8 {
    var full_body: [24]u8 = undefined;
    support.writeXyzBody(f32, .little, 2, &full_body);
    var prefix: [prefix_len]u8 = undefined;
    @memcpy(&prefix, full_body[0..prefix_len]);
    return prefix;
}

fn expectTruncation(prefix: []const u8) !void {
    const full = try makeFullPly(std.testing.allocator, xyz_header, prefix);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var stats = support.StreamStats{};
    try std.testing.expectError(
        error.TruncatedBody,
        support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, _: usize, _: u64, _: support.decode.RecordView) anyerror!void {
                return error.UnexpectedRecord; // no record may be emitted
            }
        }.visit),
    );

    // Terminal failed state; a retry is refused rather than restarted.
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .failed), parser.state);
    try std.testing.expectError(error.InvalidProducerState, internals.parser.nextRawChunkForTesting(&parser));
}

test "no body despite a positive declared record count is truncated" {
    try expectTruncation("");
}

test "a body one byte short is truncated" {
    const prefix = truncatedBody(23);
    try expectTruncation(&prefix);
}

test "a body cut halfway through the last record is truncated" {
    const prefix = truncatedBody(22);
    try expectTruncation(&prefix);
}

test "a body cut halfway through a chunk is truncated" {
    // The chunk plans 2 records (24 bytes); the body ends mid-record 2.
    const prefix = truncatedBody(18);
    try expectTruncation(&prefix);
}

test "a reader failing before delivering any bytes reports ReadFailed" {
    // The header parses normally; the reader then fails on the first
    // body read (fail_after == header length).
    var failing = support.FailingReader.init(xyz_header, xyz_header.len);

    var parser = try Parser.init(
        std.testing.allocator,
        std.testing.io,
        failing.reader(),
        .{},
    );
    defer parser.deinit();

    var stats = support.StreamStats{};
    try std.testing.expectError(
        error.ReadFailed,
        support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, _: usize, _: u64, _: support.decode.RecordView) anyerror!void {
                return error.UnexpectedRecord;
            }
        }.visit),
    );
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .failed), parser.state);
    try std.testing.expectError(error.InvalidProducerState, internals.parser.nextRawChunkForTesting(&parser));
}

test "a reader failing after earlier chunks keeps them valid, then fails" {
    var body: [24]u8 = undefined;
    support.writeXyzBody(f32, .little, 2, &body);
    const full = try makeFullPly(std.testing.allocator, xyz_header, &body);
    defer std.testing.allocator.free(full);

    // Deliver exactly the first record (12 bytes) then fail.
    var failing = support.FailingReader.init(full, xyz_header.len + 12);

    var parser = try Parser.init(
        std.testing.allocator,
        std.testing.io,
        failing.reader(),
        .{},
    );
    defer parser.deinit();
    parser.options.chunk_size = 12;

    var stats = support.StreamStats{};
    try std.testing.expectError(
        error.ReadFailed,
        support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, element_index: usize, record_index: u64, view: support.decode.RecordView) anyerror!void {
                try std.testing.expectEqual(@as(usize, 0), element_index);
                try std.testing.expectEqual(@as(u64, 0), record_index);
                try support.expectXyzRecord(f32, record_index, view);
            }
        }.visit),
    );

    // The earlier chunk was fully valid and committed...
    try std.testing.expectEqual(@as(u64, 1), stats.records);
    try std.testing.expectEqual(@as(u64, 12), stats.body_bytes);

    // ...and the failure is terminal without partial commit of the second.
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .failed), parser.state);
    try std.testing.expectEqual(@as(u64, 1), parser.producer.sequence);
    try std.testing.expectEqual(@as(u64, 1), parser.producer.next_record);
    try std.testing.expectError(error.InvalidProducerState, internals.parser.nextRawChunkForTesting(&parser));
}

test "a header with no records declared completes immediately" {
    const empty_header =
        "ply\nformat binary_little_endian 1.0\nelement vertex 0\n" ++
        "property float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(empty_header);

    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var stats = support.StreamStats{};
    try support.streamAll(&parser, &stats, {}, struct {
        fn visit(_: void, _: usize, _: u64, _: support.decode.RecordView) anyerror!void {
            return error.UnexpectedRecord;
        }
    }.visit);

    try std.testing.expectEqual(@as(u64, 0), stats.chunks);
    try std.testing.expectEqual(@as(u64, 0), stats.body_bytes);
}

test "an ASCII body is explicitly rejected with UnsupportedEncoding" {
    const body = "1 2 3\n4 5 6\n";
    const full = try makeFullPly(std.testing.allocator, ascii_header, body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    // The header itself parsed (Phase 2 accepts ASCII headers); streaming
    // its body through the binary producer is an explicit error.
    try std.testing.expectError(error.UnsupportedEncoding, internals.parser.nextRawChunkForTesting(&parser));
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .failed), parser.state);
    try std.testing.expectError(error.InvalidProducerState, internals.parser.nextRawChunkForTesting(&parser));
}

test "a nonempty list element is rejected without advancing" {
    // One 4-byte vertex record (float x), then a list-bearing face record.
    var body: [4]u8 = undefined;
    support.writeScalar(f32, .little, 1.5, &body);
    const full = try makeFullPly(std.testing.allocator, face_header, &body);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    var stats = support.StreamStats{};
    try std.testing.expectError(
        error.UnsupportedVariableLengthElement,
        support.streamAll(&parser, &stats, {}, struct {
            fn visit(_: void, element_index: usize, record_index: u64, view: support.decode.RecordView) anyerror!void {
                try std.testing.expectEqual(@as(usize, 0), element_index);
                try std.testing.expectEqual(@as(u64, 0), record_index);
                var values: [1]support.decode.ScalarValue = undefined;
                try view.decodeAll(&values);
                try std.testing.expectEqual(@as(f32, 1.5), values[0].f32);
            }
        }.visit),
    );

    // Stopped at the face element; the face body was not touched.
    try std.testing.expectEqual(@as(u64, 1), stats.records);
    try std.testing.expectEqual(@as(u64, 4), stats.body_bytes);
    try std.testing.expectEqual(@as(usize, 1), parser.producer.element_index);
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .failed), parser.state);
}

test "streaming failures release all allocations" {
    var body: [24]u8 = undefined;
    support.writeXyzBody(f32, .little, 2, &body);
    // One byte short: failure on the first chunk.
    const full = try makeFullPly(std.testing.allocator, xyz_header, body[0..23]);
    defer std.testing.allocator.free(full);

    var reader: std.Io.Reader = .fixed(full);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();

    try std.testing.expectError(error.TruncatedBody, internals.parser.nextRawChunkForTesting(&parser));
    // `defer parser.deinit()` above releases the raw buffer and header;
    // std.testing.allocator's leak check runs at test teardown.
}

test "resource-limited parsers fail cleanly under allocation failure" {
    var body: [24]u8 = undefined;
    support.writeXyzBody(f32, .little, 2, &body);
    const full = try makeFullPly(std.testing.allocator, xyz_header, &body);
    defer std.testing.allocator.free(full);

    // Drive the first raw-chunk allocation to fail at every possible
    // point: the parser either reads a chunk (and leaks nothing) or
    // reports OutOfMemory (and leaks nothing).
    var fail_index: usize = 0;
    var succeeded = false;
    while (fail_index < 100) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var reader: std.Io.Reader = .fixed(full);
        if (Parser.init(failing.allocator(), std.testing.io, &reader, .{})) |parser_value| {
            var parser = parser_value;
            if (internals.parser.nextRawChunkForTesting(&parser)) |maybe_chunk| {
                try std.testing.expect(maybe_chunk != null);
                succeeded = true;
            } else |err| switch (err) {
                error.OutOfMemory => {},
                else => return err,
            }
            parser.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        }
    }
    try std.testing.expect(succeeded);
}
