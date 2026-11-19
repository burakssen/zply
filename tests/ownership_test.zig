//! Ownership, lifecycle, and I/O contract tests (test group F).
//!
//! These test the ownership invariants around the functional initialization:
//! configuration failure consumes no reader bytes, header parsing advances
//! the reader exactly to the body boundary, `body_offset` stays relative to
//! the parser's starting position, deinit does not read, failed init
//! requires no cleanup, and owned metadata can be created and cleaned up
//! under the testing allocator.

const std = @import("std");
const ply = @import("zply");

/// A minimal PLY prefix, used to verify the parser leaves reader content
/// and position untouched in Phase 1.
const sample_ply =
    "ply\n" ++
    "format ascii 1.0\n" ++
    "element vertex 3\n" ++
    "property float x\n" ++
    "end_header\n" ++
    "1\n2\n3\n";

fn makeReader(bytes: []const u8) std.Io.Reader {
    return .fixed(bytes);
}

test "init parses the header and advances the reader to the body" {
    var reader = makeReader(sample_ply);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var parser = try ply.Parser.init(
        std.testing.allocator,
        threaded.io(),
        &reader,
        .{},
    );
    defer parser.deinit();

    // The parser consumed exactly the header (66 bytes) and nothing else.
    try std.testing.expectEqual(@as(usize, 66), reader.seek);
    // body_offset matches the consumed prefix length.
    try std.testing.expectEqual(@as(u64, 66), parser.header().body_offset);
}

test "init with invalid configuration consumes zero reader bytes" {
    var reader = makeReader(sample_ply);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var options = ply.Options{};
    options.memory_budget = 0; // invalid

    try std.testing.expectError(
        error.InvalidConfiguration,
        ply.Parser.init(std.testing.allocator, threaded.io(), &reader, options),
    );

    try std.testing.expectEqual(@as(usize, 0), reader.seek);
    try std.testing.expectEqualStrings(sample_ply, reader.buffer[0..reader.end]);
}

test "successful initialization transitions to ready and ASCII records decode" {
    var reader = makeReader(sample_ply);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var parser = try ply.Parser.init(
        std.testing.allocator,
        threaded.io(),
        &reader,
        .{},
    );
    defer parser.deinit();

    try std.testing.expectEqual(ply.Parser.State.ready, parser.state);
    const header = parser.header();
    try std.testing.expectEqualStrings("vertex", header.elements[0].name);
    // The Phase 8 ASCII path must return typed columns through the same API.
    var batch = (try parser.next()).?;
    defer batch.release();
    try std.testing.expectEqual(@as(usize, 0), batch.info().element_index);
    try std.testing.expectEqual(@as(u64, 0), batch.info().first_record);
    try std.testing.expectEqual(@as(usize, 3), batch.info().record_count);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, try batch.typedColumn(f32, 0));
    try std.testing.expect((try parser.next()) == null);
}

test "deinit does not read from the reader and leaves it usable" {
    var reader = makeReader(sample_ply);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var parser = try ply.Parser.init(
        std.testing.allocator,
        threaded.io(),
        &reader,
        .{},
    );
    const position = reader.seek; // after header parsing
    parser.deinit();

    try std.testing.expectEqual(ply.Parser.State.destroyed, parser.state);
    // Invariant 6: destruction must not consume bytes to reach EOF.
    try std.testing.expectEqual(position, reader.seek);
    // The reader remains usable by the caller afterwards.
    try std.testing.expectEqualStrings(sample_ply, reader.buffer[0..reader.end]);
}

test "init with a mid-stream reader starts exactly at the current position" {
    // The caller has already consumed the first 10 bytes of some stream.
    const stream = "0123456789" ++ sample_ply ++ "trailing";
    var reader = makeReader(stream);
    reader.seek = 10; // logical position: start of the PLY document

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var parser = try ply.Parser.init(
        std.testing.allocator,
        threaded.io(),
        &reader,
        .{},
    );
    defer parser.deinit();

    // body_offset is relative to the parser's starting position.
    try std.testing.expectEqual(@as(u64, 66), parser.header().body_offset);
    try std.testing.expectEqual(@as(usize, 10 + 66), reader.seek);
}

// ---------------------------------------------------------------------------
// Owned metadata lifecycle (the contract the parser implements in Phase 2)
// ---------------------------------------------------------------------------

test "owned metadata can be created and fully cleaned up" {
    const allocator = std.testing.allocator;

    // Simulate parser-owned header storage: every string duplicated, every
    // slice allocated, all released together. Phase 2 moves this lifecycle
    // into the parser itself. The testing allocator fails the test on any
    // leak, including on early-exit paths.

    const vertex_name = try allocator.dupe(u8, "vertex");
    errdefer allocator.free(vertex_name);
    const face_name = try allocator.dupe(u8, "face");
    errdefer allocator.free(face_name);

    const comment = try allocator.dupe(u8, "created by a test");
    errdefer allocator.free(comment);

    const vertex_properties = try allocator.alloc(ply.Property, 3);
    errdefer allocator.free(vertex_properties);
    vertex_properties[0] = ply.Property.scalar("x", .f64);
    vertex_properties[1] = ply.Property.scalar("y", .f64);
    vertex_properties[2] = ply.Property.scalar("z", .f64);

    const face_properties = try allocator.alloc(ply.Property, 1);
    errdefer allocator.free(face_properties);
    face_properties[0] = ply.Property.list("vertex_indices", .u8, .i32);

    const elements = try allocator.alloc(ply.Element, 2);
    errdefer allocator.free(elements);
    elements[0] = .{ .name = vertex_name, .count = 8, .properties = vertex_properties };
    elements[1] = .{ .name = face_name, .count = 12, .properties = face_properties };

    const comments = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(comments);
    comments[0] = comment;

    const header = ply.Header{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = elements,
        .comments = comments,
        .obj_info = &.{},
        .body_offset = 130,
    };

    // The header is fully self-contained: no reference into any reader.
    try std.testing.expectEqual(@as(usize, 2), header.elements.len);
    try std.testing.expectEqualStrings("face", header.elements[1].name);
    try std.testing.expectEqual(@as(u64, 130), header.body_offset);

    // Cleanup (mirrored by the errdefers on failure paths).
    allocator.free(comments);
    allocator.free(elements);
    allocator.free(face_properties);
    allocator.free(vertex_properties);
    allocator.free(comment);
    allocator.free(face_name);
    allocator.free(vertex_name);
}

test "owned metadata cleanup does not modify the reader" {
    const allocator = std.testing.allocator;
    const reader = makeReader(sample_ply);

    // Metadata that borrows nothing from the reader's buffer.
    const name = try allocator.dupe(u8, "vertex");
    defer allocator.free(name);

    const element = ply.Element{
        .name = name,
        .count = 3,
        .properties = &.{
            ply.Property.scalar("x", .f32),
            ply.Property.scalar("y", .f32),
            ply.Property.scalar("z", .f32),
        },
    };

    // "Release" the metadata: the name string goes out of scope via defer.
    // The reader is untouched by metadata ownership.
    try std.testing.expectEqualStrings("vertex", element.name);
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "element without owned storage still validates widths after cleanup" {
    // Derived widths do not depend on allocation; the fixed-record-size
    // calculation is pure and survives metadata release.
    const properties = [_]ply.Property{
        ply.Property.scalar("x", .f64),
        ply.Property.scalar("y", .f64),
        ply.Property.scalar("z", .f64),
    };
    const element = ply.Element{
        .name = "vertex",
        .count = 100,
        .properties = &properties,
    };
    try std.testing.expectEqual(@as(?usize, 24), try element.fixedRecordSize());
}

test "documented lifecycle preconditions are enforced" {
    var reader = makeReader(sample_ply);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var parser = try ply.Parser.init(
        std.testing.allocator,
        threaded.io(),
        &reader,
        .{},
    );
    defer parser.deinit();

    // `header` requires successful initialization; on a live parser it
    // returns the parser-owned header without touching the reader.
    const header = parser.header();
    try std.testing.expectEqualStrings("x", header.elements[0].properties[0].name);
    try std.testing.expectEqual(ply.Parser.State.ready, parser.state);
}

test "failed init requires no cleanup and does not touch the reader afterwards" {
    // A malformed header after several valid lines: the reader has already
    // advanced (initialization is not transactional), all parser-owned
    // allocations are released, and the caller must not call deinit.
    const malformed =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 3\n" ++
        "property bogus_type z\n" ++
        "end_header\n";
    var reader = makeReader(malformed);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try std.testing.expectError(
        error.InvalidScalarType,
        ply.Parser.init(std.testing.allocator, threaded.io(), &reader, .{}),
    );
    // No cleanup to perform; the reader is simply left where parsing
    // stopped (inside or after the malformed line).
    try std.testing.expect(reader.seek > 0);
}
