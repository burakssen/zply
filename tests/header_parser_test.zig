//! Tests for the header grammar, state machine, metadata ownership, and
//! layout integration (Tasks 2.3–2.11), exercised through the internal
//! `parseHeader` entry point.
//!
//! Uses the internals module exclusively; `zply`-module types are never
//! mixed in.

const std = @import("std");
const internals = @import("zply_internals");

const parseHeader = internals.header_parser.parseHeader;
const HeaderStorage = internals.header_parser.HeaderStorage;
const Options = internals.options.Options;
const Header = internals.header.Header;

/// Parses `bytes` with the testing allocator. The caller owns the returned
/// storage and must `deinit` it.
fn parse(bytes: []const u8, options: Options) !HeaderStorage {
    var reader: std.Io.Reader = .fixed(bytes);
    return parseHeader(std.testing.allocator, &reader, options);
}

fn defaultOptions() Options {
    return .{};
}

test "minimal ASCII header: encoding, version, body offset" {
    const bytes = "ply\nformat ascii 1.0\nend_header\n";
    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const header = &storage.header;
    try std.testing.expectEqual(internals.types.Encoding.ascii, header.encoding);
    try std.testing.expectEqual(@as(u16, 1), header.version.major);
    try std.testing.expectEqual(@as(u16, 0), header.version.minor);
    try std.testing.expectEqual(@as(usize, 0), header.elements.len);
    try std.testing.expectEqual(@as(usize, 0), header.comments.len);
    try std.testing.expectEqual(@as(usize, 0), header.obj_info.len);
    try std.testing.expectEqual(@as(u64, 32), header.body_offset);
    try std.testing.expectEqual(@as(usize, 0), storage.layouts.len);
}

test "binary little-endian and big-endian encodings" {
    const le = "ply\nformat binary_little_endian 1.0\nend_header\n";
    var storage = try parse(le, defaultOptions());
    defer storage.deinit();
    try std.testing.expectEqual(
        internals.types.Encoding.binary_little_endian,
        storage.header.encoding,
    );
    try std.testing.expectEqual(@as(u64, 47), storage.header.body_offset);

    const be = "ply\nformat binary_big_endian 1.0\nend_header\n";
    var storage2 = try parse(be, defaultOptions());
    defer storage2.deinit();
    try std.testing.expectEqual(
        internals.types.Encoding.binary_big_endian,
        storage2.header.encoding,
    );
    try std.testing.expectEqual(@as(u64, 47), storage.header.body_offset);
}

test "vertex + face schema: declaration order, counts, and layouts" {
    const bytes =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "comment Generated point cloud\n" ++
        "element vertex 1000000\n" ++
        "property double x\n" ++
        "property double y\n" ++
        "property double z\n" ++
        "property uchar red\n" ++
        "property uchar green\n" ++
        "property uchar blue\n" ++
        "element face 500000\n" ++
        "property list uchar int vertex_indices\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const header = &storage.header;
    try std.testing.expectEqual(@as(usize, 2), header.elements.len);

    const vertex = header.elements[0];
    try std.testing.expectEqualStrings("vertex", vertex.name);
    try std.testing.expectEqual(@as(u64, 1000000), vertex.count);
    try std.testing.expectEqual(@as(usize, 6), vertex.properties.len);
    try std.testing.expectEqualStrings("x", vertex.properties[0].name);
    try std.testing.expectEqual(internals.types.ScalarType.f64, vertex.properties[0].scalarType().?);
    try std.testing.expectEqualStrings("red", vertex.properties[3].name);
    try std.testing.expectEqual(internals.types.ScalarType.u8, vertex.properties[3].scalarType().?);

    const face = header.elements[1];
    try std.testing.expectEqualStrings("face", face.name);
    try std.testing.expectEqual(@as(u64, 500000), face.count);
    try std.testing.expectEqualStrings(
        "vertex_indices",
        face.properties[0].name,
    );

    const list_info = face.properties[0].listInfo().?;
    try std.testing.expectEqual(internals.types.IntegerType.u8, list_info.count_type);
    try std.testing.expectEqual(internals.types.ScalarType.i32, list_info.item_type);

    try std.testing.expectEqualStrings("Generated point cloud", header.comments[0]);

    // Compiled layouts: vertex is fixed 27 bytes (3*8 + 3*1), face variable.
    try std.testing.expectEqual(@as(usize, 2), storage.layouts.len);
    const vertex_layout = storage.layouts[0];
    try std.testing.expectEqual(@as(?usize, 27), vertex_layout.fixed_record_size);
    try std.testing.expectEqual(@as(usize, 27), vertex_layout.minimum_record_size);
    try std.testing.expectEqual(@as(usize, 6), vertex_layout.properties.len);
    try std.testing.expectEqual(@as(?usize, 0), vertex_layout.properties[0].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 16), vertex_layout.properties[2].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 26), vertex_layout.properties[5].fixed_offset);

    const face_layout = storage.layouts[1];
    try std.testing.expectEqual(@as(?usize, null), face_layout.fixed_record_size);
    try std.testing.expectEqual(@as(usize, 1), face_layout.minimum_record_size);
    // The face body starts right after the vertex body (1,000,000 * 27).
    try std.testing.expectEqual(@as(u64, 27000000), face_layout.body_start_offset.?);
}

test "comments preserve interior spacing and skip exactly one separator" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "comment The   spaces   here matter\n" ++
        "comment\n" ++
        "comment \n" ++
        "comment\tdoubled\ttabs\tstay\n" ++
        "obj_info Dataset: Stanford Bunny\n" ++
        "obj_info\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const header = &storage.header;
    try std.testing.expectEqual(@as(usize, 4), header.comments.len);
    try std.testing.expectEqualStrings("The   spaces   here matter", header.comments[0]);
    try std.testing.expectEqual(@as(usize, 0), header.comments[1].len);
    try std.testing.expectEqual(@as(usize, 0), header.comments[2].len);
    try std.testing.expectEqualStrings("doubled\ttabs\tstay", header.comments[3]);

    try std.testing.expectEqual(@as(usize, 2), header.obj_info.len);
    try std.testing.expectEqualStrings("Dataset: Stanford Bunny", header.obj_info[0]);
    try std.testing.expectEqual(@as(usize, 0), header.obj_info[1].len);
}

test "comments and obj_info do not reset the active element" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 100\n" ++
        "property float x\n" ++
        "comment Position attributes\n" ++
        "obj_info some metadata\n" ++
        "property float y\n" ++
        "property float z\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const header = &storage.header;
    try std.testing.expectEqual(@as(usize, 1), header.elements.len);
    try std.testing.expectEqual(@as(usize, 3), header.elements[0].properties.len);
    try std.testing.expectEqualStrings("z", header.elements[0].properties[2].name);
}

test "tabs are accepted as separators between structural tokens" {
    const bytes =
        "ply\n" ++
        "format\tascii\t1.0\n" ++
        "element\tvertex\t3\n" ++
        "property\tfloat\tx\n" ++
        "property list\tuchar\tint\tindices\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    try std.testing.expectEqualStrings("vertex", storage.header.elements[0].name);
    try std.testing.expectEqual(@as(usize, 2), storage.header.elements[0].properties.len);
    try std.testing.expectEqualStrings("indices", storage.header.elements[0].properties[1].name);
}

test "CRLF header: identical metadata, both CRLF bytes counted" {
    const bytes =
        "ply\r\n" ++
        "format binary_big_endian 1.0\r\n" ++
        "element vertex 2\r\n" ++
        "property uchar x\r\n" ++
        "end_header\r\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    try std.testing.expectEqual(
        internals.types.Encoding.binary_big_endian,
        storage.header.encoding,
    );
    try std.testing.expectEqual(@as(usize, 1), storage.header.elements.len);
    try std.testing.expectEqualStrings("x", storage.header.elements[0].properties[0].name);
    // Every CRLF byte is counted: the exact serialized length is 83.
    try std.testing.expectEqual(@as(u64, 83), storage.header.body_offset);
}

test "blank header lines are skipped" {
    const bytes =
        "ply\n" ++
        "\n" ++
        "format ascii 1.0\n" ++
        "\n\n" ++
        "element vertex 1\n" ++
        "property float x\n" ++
        "\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 1), storage.header.elements.len);
}

test "all eight canonical scalar types parse to the right internal types" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 1\n" ++
        "property char a\n" ++
        "property uchar b\n" ++
        "property short c\n" ++
        "property ushort d\n" ++
        "property int e\n" ++
        "property uint f\n" ++
        "property float g\n" ++
        "property double h\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const expected = [_]internals.types.ScalarType{
        .i8, .u8, .i16, .u16, .i32, .u32, .f32, .f64,
    };
    const properties = storage.header.elements[0].properties;
    try std.testing.expectEqual(@as(usize, 8), properties.len);
    for (expected, 0..) |want, i| {
        try std.testing.expectEqual(want, properties[i].scalarType().?);
    }
}

test "standard integer aliases resolve in strict mode" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 1\n" ++
        "property int8 a\n" ++
        "property uint8 b\n" ++
        "property int16 c\n" ++
        "property uint16 d\n" ++
        "property int32 e\n" ++
        "property uint32 f\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const expected = [_]internals.types.ScalarType{ .i8, .u8, .i16, .u16, .i32, .u32 };
    const properties = storage.header.elements[0].properties;
    for (expected, 0..) |want, i| {
        try std.testing.expectEqual(want, properties[i].scalarType().?);
    }
}

test "compatibility mode accepts float32/float64 and case-insensitive names" {
    var options = defaultOptions();
    options.strict = false;

    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 1\n" ++
        "property float32 a\n" ++
        "property float64 b\n" ++
        "property UINT c\n" ++
        "property Double d\n" ++
        "end_header\n";

    var storage = try parse(bytes, options);
    defer storage.deinit();

    const properties = storage.header.elements[0].properties;
    try std.testing.expectEqual(internals.types.ScalarType.f32, properties[0].scalarType().?);
    try std.testing.expectEqual(internals.types.ScalarType.f64, properties[1].scalarType().?);
    try std.testing.expectEqual(internals.types.ScalarType.u32, properties[2].scalarType().?);
    try std.testing.expectEqual(internals.types.ScalarType.f64, properties[3].scalarType().?);
}

test "compatibility mode keeps duplicate element declarations separate" {
    var options = defaultOptions();
    options.strict = false;

    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 2\n" ++
        "property float x\n" ++
        "element vertex 3\n" ++
        "property float y\n" ++
        "end_header\n";

    var storage = try parse(bytes, options);
    defer storage.deinit();

    try std.testing.expectEqual(@as(usize, 2), storage.header.elements.len);
    try std.testing.expectEqual(@as(u64, 2), storage.header.elements[0].count);
    try std.testing.expectEqual(@as(u64, 3), storage.header.elements[1].count);
    try std.testing.expectEqualStrings("x", storage.header.elements[0].properties[0].name);
    try std.testing.expectEqualStrings("y", storage.header.elements[1].properties[0].name);
}

test "compatibility mode keeps duplicate property declarations separate" {
    var options = defaultOptions();
    options.strict = false;

    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 2\n" ++
        "property float x\n" ++
        "property float x\n" ++
        "end_header\n";

    var storage = try parse(bytes, options);
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 2), storage.header.elements[0].properties.len);
}

test "all six integer count types are accepted" {
    const count_names = [_][]const u8{ "char", "uchar", "short", "ushort", "int", "uint" };
    for (count_names) |count_name| {
        var buffer: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &buffer,
            "ply\nformat ascii 1.0\nelement face 1\nproperty list {s} int i\nend_header\n",
            .{count_name},
        );
        var storage = try parse(bytes, defaultOptions());
        defer storage.deinit();

        const list_info = storage.header.elements[0].properties[0].listInfo().?;
        const expected: internals.types.IntegerType = switch (count_name[0]) {
            'c' => .i8,
            'u' => switch (count_name[1]) {
                'c' => .u8,
                's' => .u16,
                'i' => .u32,
                else => unreachable,
            },
            's' => .i16,
            'i' => .i32,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, list_info.count_type);
    }
}

test "list item types may be any scalar, including floats" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element face 1\n" ++
        "property list uchar float weights\n" ++
        "property list uint double moments\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const info0 = storage.header.elements[0].properties[0].listInfo().?;
    try std.testing.expectEqual(internals.types.ScalarType.f32, info0.item_type);
    const info1 = storage.header.elements[0].properties[1].listInfo().?;
    try std.testing.expectEqual(internals.types.ScalarType.f64, info1.item_type);
}

test "zero-record and zero-property elements are representable" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element face 0\n" ++
        "property list uchar int vertex_indices\n" ++
        "element empty 0\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const header = &storage.header;
    try std.testing.expectEqual(@as(u64, 0), header.elements[0].count);
    try std.testing.expectEqual(@as(u64, 0), header.elements[1].count);
    try std.testing.expectEqual(@as(usize, 0), header.elements[1].properties.len);
    try std.testing.expectEqual(@as(?usize, 0), storage.layouts[1].fixed_record_size);
}

test "declared counts above 2^32 are preserved without allocation" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 4294967296\n" ++
        "property float x\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();
    try std.testing.expectEqual(@as(u64, 4294967296), storage.header.elements[0].count);
}

test "arbitrary element and property names are preserved" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element my_custom_element 1\n" ++
        "property float confidence\n" ++
        "property double my_custom_attribute\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    try std.testing.expectEqualStrings(
        "my_custom_element",
        storage.header.elements[0].name,
    );
    try std.testing.expectEqualStrings(
        "my_custom_attribute",
        storage.header.elements[0].properties[1].name,
    );
}

test "metadata survives line scratch reuse (no borrowing from the reader)" {
    // Many lines with identical keywords force the scratch buffer to be
    // reused constantly; all stored names/payloads must remain intact.
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element aaa 1\n" ++
        "property float p1\n" ++
        "property float p2\n" ++
        "element bbb 1\n" ++
        "property float p1\n" ++
        "comment comment comment comment\n" ++
        "element ccc 1\n" ++
        "property list uchar int p1\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();

    const header = &storage.header;
    try std.testing.expectEqualStrings("aaa", header.elements[0].name);
    try std.testing.expectEqualStrings("p2", header.elements[0].properties[1].name);
    try std.testing.expectEqualStrings("bbb", header.elements[1].name);
    try std.testing.expectEqualStrings("p1", header.elements[1].properties[0].name);
    try std.testing.expectEqualStrings("comment comment comment", header.comments[0]);
    try std.testing.expectEqualStrings("ccc", header.elements[2].name);
    try std.testing.expectEqualStrings("p1", header.elements[2].properties[0].name);
}

test "same property name may appear in different elements" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 1\n" ++
        "property float x\n" ++
        "element camera 1\n" ++
        "property float x\n" ++
        "end_header\n";

    var storage = try parse(bytes, defaultOptions());
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 2), storage.header.elements.len);
    try std.testing.expectEqualStrings("x", storage.header.elements[1].properties[0].name);
}

test "body bytes immediately after end_header are preserved" {
    const bytes =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "element vertex 1\n" ++
        "property uchar x\n" ++
        "end_header\n" ++
        "\x00\xFF\x10\x20";

    var reader: std.Io.Reader = .fixed(bytes);
    var storage = try parseHeader(std.testing.allocator, &reader, defaultOptions());
    defer storage.deinit();

    // The reader is positioned exactly at the first body byte.
    try std.testing.expectEqual(@as(u64, bytes.len - 4), storage.header.body_offset);
    try std.testing.expectEqual(@as(u8, 0x00), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0xFF), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0x10), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0x20), try reader.takeByte());
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
}

test "header at a nonzero reader position: relative body offset" {
    // The caller consumed 10 bytes of some larger stream first.
    const prefix = "0123456789";
    const document = prefix ++
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 1\n" ++
        "property float x\n" ++
        "end_header\n" ++
        "BODY";

    var reader: std.Io.Reader = .fixed(document);
    reader.seek = prefix.len;

    var storage = try parseHeader(std.testing.allocator, &reader, defaultOptions());
    defer storage.deinit();

    // body_offset is relative to the parser's starting position.
    const header_len: u64 = document.len - prefix.len - 4;
    try std.testing.expectEqual(header_len, storage.header.body_offset);
    try std.testing.expectEqual(@as(u8, 'B'), try reader.takeByte());
}

test "header exactly at the total byte limit passes through the parser" {
    const bytes = "ply\nformat ascii 1.0\nend_header\n";
    var options = defaultOptions();
    options.limits.max_header_bytes = 32;

    var storage = try parse(bytes, options);
    defer storage.deinit();
    try std.testing.expectEqual(@as(u64, 32), storage.header.body_offset);
}

test "one-byte-at-a-time reader yields identical metadata" {
    const bytes =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "comment fragmented\n" ++
        "element vertex 2\n" ++
        "property float x\n" ++
        "element face 1\n" ++
        "property list uchar int i\n" ++
        "end_header\n";

    var reader_a: std.Io.Reader = .fixed(bytes);
    var storage_a = try parseHeader(std.testing.allocator, &reader_a, defaultOptions());
    defer storage_a.deinit();

    var underlying_b: std.Io.Reader = .fixed(bytes);
    var buf_b: [1]u8 = undefined;
    var limited_b: std.Io.Reader.Limited = .init(&underlying_b, .unlimited, &buf_b);
    var storage_b = try parseHeader(std.testing.allocator, &limited_b.interface, defaultOptions());
    defer storage_b.deinit();

    const a = &storage_a.header;
    const b = &storage_b.header;
    try std.testing.expectEqual(a.encoding, b.encoding);
    try std.testing.expectEqual(a.body_offset, b.body_offset);
    try std.testing.expectEqual(a.elements.len, b.elements.len);
    for (a.elements, b.elements) |ea, eb| {
        try std.testing.expectEqualStrings(ea.name, eb.name);
        try std.testing.expectEqual(ea.count, eb.count);
        try std.testing.expectEqual(ea.properties.len, eb.properties.len);
        for (ea.properties, eb.properties) |pa, pb| {
            try std.testing.expectEqualStrings(pa.name, pb.name);
            try std.testing.expect(std.mem.eql(u8, @tagName(pa.kind), @tagName(pb.kind)));
        }
    }
    try std.testing.expectEqualStrings(a.comments[0], b.comments[0]);
}
