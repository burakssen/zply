//! Public API surface tests (Task 1.12): the exported module must expose a
//! coherent type system, and the schema relationships must compose without
//! any parsing or decoding implementation.

const std = @import("std");
const ply = @import("zply");

test "public exports exist and are the intended types" {
    // Parser & configuration.
    try std.testing.expect(@TypeOf(ply.Parser.init) != void);
    try std.testing.expect(@TypeOf(ply.Parser.header) != void);
    try std.testing.expect(@TypeOf(ply.Parser.next) != void);
    try std.testing.expect(@TypeOf(ply.Parser.deinit) != void);
    try std.testing.expect(@TypeOf(ply.Options.validate) != void);

    // Format types.
    _ = ply.Batch;
    _ = ply.Encoding;
    _ = ply.Version;
    _ = ply.ScalarType;
    _ = ply.IntegerType;
    _ = ply.Property;
    _ = ply.Element;
    _ = ply.Header;
    _ = ply.PropertyLayout;
    _ = ply.ElementLayout;
    _ = ply.Limits;
    _ = ply.Error;
    _ = ply.Diagnostic;

    // Phase 3: typed decoded values and the pure decode engine.
    _ = ply.ScalarValue;
    _ = ply.decode.ScalarValue;
    _ = ply.decode.FixedLayout;
    _ = ply.decode.RecordView;
    _ = ply.decode.DecodeError;
    _ = ply.decode.decodeScalar;
    _ = ply.decode.decodeScalarAs;
    _ = ply.decode.decodeProperty;
    _ = ply.decode.decodeRecord;
    _ = ply.decode.decodeRange;
    _ = ply.decode.recordCountForRange;
    _ = ply.decode.endianFor;
}

test "no filesystem, thread, or seeking methods on the public surface" {
    // Public API rules: no openFile, no setWorkers/startThreadPool, no
    // seekToRecord in Phase 1.
    const parser_decls = @typeInfo(ply.Parser).@"struct".decl_names;
    for (parser_decls) |decl_name| {
        try std.testing.expect(!std.mem.eql(u8, decl_name, "openFile"));
        try std.testing.expect(!std.mem.eql(u8, decl_name, "setWorkers"));
        try std.testing.expect(!std.mem.eql(u8, decl_name, "startThreadPool"));
        try std.testing.expect(!std.mem.eql(u8, decl_name, "seekToRecord"));
        try std.testing.expect(!std.mem.endsWith(u8, decl_name, "Workers"));
        try std.testing.expect(!std.mem.endsWith(u8, decl_name, "Thread"));
    }
}

test "a complete header can be represented: vertex + face element" {
    // The full-file schema, constructed manually (Phase 2 populates it by
    // parsing):
    //
    //     ply
    //     format binary_little_endian 1.0
    //     element vertex 1000000
    //     property float x
    //     property float y
    //     property float z
    //     property uchar red
    //     property uchar green
    //     property uchar blue
    //     element face 200000
    //     property list uchar int vertex_indices
    //     end_header
    const vertex_properties = [_]ply.Property{
        ply.Property.scalar("x", .f32),
        ply.Property.scalar("y", .f32),
        ply.Property.scalar("z", .f32),
        ply.Property.scalar("red", .u8),
        ply.Property.scalar("green", .u8),
        ply.Property.scalar("blue", .u8),
    };
    const face_properties = [_]ply.Property{
        ply.Property.list("vertex_indices", .u8, .i32),
    };

    const elements = [_]ply.Element{
        .{
            .name = "vertex",
            .count = 1000000,
            .properties = &vertex_properties,
        },
        .{
            .name = "face",
            .count = 200000,
            .properties = &face_properties,
        },
    };

    const header = ply.Header{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
        .comments = &.{
            "element order and property order are preserved",
        },
        .obj_info = &.{"a representative schema"},
        .body_offset = 211,
    };

    // Access in header order; iteration order is declaration order.
    try std.testing.expectEqualStrings("vertex", header.elements[0].name);
    try std.testing.expectEqualStrings("face", header.elements[1].name);
    try std.testing.expectEqualStrings("x", header.elements[0].properties[0].name);
    try std.testing.expectEqualStrings("blue", header.elements[0].properties[5].name);
    try std.testing.expectEqualStrings("vertex_indices", header.elements[1].properties[0].name);

    // Metadata is queryable without the reader.
    try std.testing.expectEqual(@as(usize, 1), header.comments.len);
    try std.testing.expectEqual(@as(usize, 1), header.obj_info.len);
    try std.testing.expectEqual(@as(u64, 211), header.body_offset);
    try std.testing.expectEqual(
        @as(u64, 1200000),
        try header.totalRecordCount(),
    );
}

test "property iteration order and property kinds" {
    const properties = [_]ply.Property{
        ply.Property.scalar("intensity", .u8),
        ply.Property.list("knn", .u16, .f32),
    };

    try std.testing.expect(properties[0].isScalar());
    try std.testing.expect(!properties[0].isList());
    try std.testing.expectEqual(ply.ScalarType.u8, properties[0].scalarType().?);
    try std.testing.expectEqual(@as(?usize, 1), properties[0].fixedWidth());
    try std.testing.expectEqual(@as(?ply.Property.List, null), properties[0].listInfo());

    try std.testing.expect(properties[1].isList());
    try std.testing.expect(!properties[1].isScalar());
    try std.testing.expectEqual(@as(?ply.ScalarType, null), properties[1].scalarType());
    try std.testing.expectEqual(@as(?usize, null), properties[1].fixedWidth());

    const list_info = properties[1].listInfo().?;
    try std.testing.expectEqual(ply.IntegerType.u16, list_info.count_type);
    try std.testing.expectEqual(ply.ScalarType.f32, list_info.item_type);
    try std.testing.expectEqual(@as(?usize, 2), properties[1].listCountWidth());
}

test "empty property name is a validation failure" {
    const bad = ply.Property.scalar("", .f32);
    try std.testing.expectError(error.EmptyPropertyName, bad.validate());

    const bad_list = ply.Property.list("", .u8, .i32);
    try std.testing.expectError(error.EmptyPropertyName, bad_list.validate());

    const good = ply.Property.scalar("anything_at_all", .u16);
    try good.validate();
}

test "arbitrary case-sensitive property names are preserved" {
    const names = [_][]const u8{
        "x",              "y",
        "z",              "nx",
        "ny",             "nz",
        "red",            "green",
        "blue",           "vertex_indices",
        "vertex_indices", "Alpha_beta_0",
        "wedge_count",
        "Übergang",
    };
    for (names, 0..) |name, i| {
        const property = ply.Property.scalar(name, .f64);
        try property.validate();
        try std.testing.expectEqualStrings(name, property.name);
        _ = i;
    }

    // Case-sensitivity: distinct names stay distinct; no hardcoded matching.
    const lower = ply.Property.scalar("x", .f32);
    const upper = ply.Property.scalar("X", .f32);
    try std.testing.expect(!std.mem.eql(u8, lower.name, upper.name));
}

test "empty header metadata and zero-record elements" {
    const header = ply.Header.empty(.ascii);
    try std.testing.expectEqual(ply.Encoding.ascii, header.encoding);
    try std.testing.expectEqual(@as(usize, 0), header.elementCount());
    try std.testing.expectEqual(@as(u64, 0), try header.totalRecordCount());

    const element = ply.Element{
        .name = "unused",
        .count = 0,
        .properties = &.{},
    };
    try std.testing.expectEqual(@as(u64, 0), element.count);
    try std.testing.expectEqual(@as(?usize, 0), try element.fixedRecordSize());
    try std.testing.expect(element.isFixedWidth());
}

test "large declared counts above 2^32 are preserved" {
    const above_u32: u64 = 1 << 33; // 8589934592
    const properties = [_]ply.Property{ply.Property.scalar("x", .f32)};
    const element = ply.Element{
        .name = "vertex",
        .count = above_u32,
        .properties = &properties,
    };
    try std.testing.expectEqual(above_u32, element.count);
}

test "fixed record size calculations with checked arithmetic" {
    // 3 x f64 = 24.
    const xyz = [_]ply.Property{
        ply.Property.scalar("x", .f64),
        ply.Property.scalar("y", .f64),
        ply.Property.scalar("z", .f64),
    };
    const vertex = ply.Element{ .name = "vertex", .count = 4, .properties = &xyz };
    try std.testing.expectEqual(@as(?usize, 24), try vertex.fixedRecordSize());

    // 3 x f32 + 1 x u8 = 13. (The "XYZRGB f32/u8" row: per-record width 13.)
    const xyzrgb = [_]ply.Property{
        ply.Property.scalar("x", .f32),
        ply.Property.scalar("y", .f32),
        ply.Property.scalar("z", .f32),
        ply.Property.scalar("r", .u8),
    };
    const colored = ply.Element{ .name = "vertex", .count = 4, .properties = &xyzrgb };
    try std.testing.expectEqual(@as(?usize, 13), try colored.fixedRecordSize());

    // 8 + 8 + 8 + 1 = 25, the doc-comment example.
    const mixed = [_]ply.Property{
        ply.Property.scalar("x", .f64),
        ply.Property.scalar("y", .f64),
        ply.Property.scalar("z", .f64),
        ply.Property.scalar("intensity", .u8),
    };
    const intensity = ply.Element{ .name = "vertex", .count = 4, .properties = &mixed };
    try std.testing.expectEqual(@as(?usize, 25), try intensity.fixedRecordSize());

    // Any list property makes the record width unknown.
    const with_list = [_]ply.Property{
        ply.Property.scalar("x", .f32),
        ply.Property.list("vertex_indices", .u8, .i32),
    };
    const face = ply.Element{ .name = "face", .count = 3, .properties = &with_list };
    try std.testing.expectEqual(@as(?usize, null), try face.fixedRecordSize());
    try std.testing.expect(!face.isFixedWidth());

    // A list whose count and item types have different widths is
    // representable; only the count width is fixed.
    const property = ply.Property.list("edges", .u32, .u8);
    try std.testing.expectEqual(@as(usize, 4), property.listCountWidth().?);
    try std.testing.expectEqual(@as(usize, 1), property.listInfo().?.item_type.byteWidth());
}

test "checked size arithmetic rejects overflow instead of wrapping" {
    // Direct contract test of the checked addition used for all width
    // summations; real schemas cannot produce overflowing widths, so the
    // helper is exercised directly.
    const max_usize = std.math.maxInt(usize);
    try std.testing.expectError(
        error.RecordSizeOverflow,
        ply.Element.addSize(max_usize, 1),
    );
    try std.testing.expectError(
        error.RecordSizeOverflow,
        ply.Element.addSize(max_usize, max_usize),
    );
    try std.testing.expectEqual(@as(usize, 25), try ply.Element.addSize(24, 1));

    // Declared counts above usize width are rejected, never truncated
    // (32-bit targets only; on 64-bit this conversion always succeeds).
    const properties = [_]ply.Property{ply.Property.scalar("x", .f32)};
    if (@bitSizeOf(usize) < 64) {
        const element = ply.Element{
            .name = "vertex",
            .count = 1 << 40,
            .properties = &properties,
        };
        try std.testing.expectError(error.RecordSizeOverflow, element.countAsSize());
    } else {
        const element = ply.Element{
            .name = "vertex",
            .count = 1 << 40,
            .properties = &properties,
        };
        try std.testing.expectEqual(@as(usize, 1 << 40), try element.countAsSize());
    }
}

test "diagnostic shape uses wide types and optional context" {
    const diagnostic = ply.Diagnostic{
        .category = .record,
        .element_index = 1,
        .property_index = 3,
        .record_index = 8589934592,
        .byte_offset = 12345678901,
    };
    try std.testing.expectEqual(ply.Diagnostic.Category.record, diagnostic.category);
    try std.testing.expectEqual(@as(u64, 8589934592), diagnostic.record_index.?);
    try std.testing.expectEqual(@as(u64, 12345678901), diagnostic.byte_offset.?);

    // Configuration diagnostics carry no positional context.
    const config_diagnostic = ply.Diagnostic{ .category = .configuration };
    try std.testing.expectEqual(
        @as(?u64, null),
        config_diagnostic.element_index,
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        config_diagnostic.byte_offset,
    );
}

test "parser construction API matches the intended reader-first signature" {
    var reader: std.Io.Reader = .fixed(sample);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    // The exact construction pattern from the docs:
    //     var parser = try ply.Parser.init(allocator, io, &reader, .{});
    var parser = try ply.Parser.init(
        std.testing.allocator,
        threaded.io(),
        &reader,
        .{},
    );
    defer parser.deinit();

    // Initialization parses the header and keeps the reader-first API.
    // A file declaring no elements has no body records to return.
    const header = parser.header();
    try std.testing.expectEqual(ply.Encoding.ascii, header.encoding);
    try std.testing.expectEqual(@as(u64, sample.len), header.body_offset);
    try std.testing.expect((try parser.next()) == null);
}

const sample = "ply\nformat ascii 1.0\nend_header\n";
