//! Layout compilation tests (Task 2.11): fixed offsets, record widths,
//! variable-width structure, body offsets, and checked overflow.
//!
//! Uses the internals module exclusively; schemas are constructed manually
//! with the internal data model and compared against `compileSchema`, and
//! parsed headers are cross-checked against manually compiled layouts.

const std = @import("std");
const internals = @import("zply_internals");

const Property = internals.property.Property;
const Element = internals.element.Element;
const Header = internals.header.Header;
const layout = internals.layout;
const PropertyLayout = layout.PropertyLayout;
const ElementLayout = layout.ElementLayout;
const types = internals.types;

/// Compiles a schema from manually constructed elements.
fn compile(elements: []const Element) ![]ElementLayout {
    const header = Header{
        .encoding = .ascii,
        .version = .{ .major = 1, .minor = 0 },
        .elements = elements,
    };
    return layout.compileSchema(std.testing.allocator, &header);
}

/// One scalar property per element convenience.
fn scalarElement(name: []const u8, count: u64, properties: []const Property) Element {
    return .{ .name = name, .count = count, .properties = properties };
}

test "three f32 properties: 12-byte fixed record with offsets 0/4/8" {
    const properties = [_]Property{
        Property.scalar("x", .f32),
        Property.scalar("y", .f32),
        Property.scalar("z", .f32),
    };
    const elements = [_]Element{scalarElement("vertex", 10, &properties)};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    try std.testing.expectEqual(@as(?usize, 12), layouts[0].fixed_record_size);
    try std.testing.expectEqual(@as(usize, 12), layouts[0].minimum_record_size);
    try std.testing.expectEqual(@as(?usize, 0), layouts[0].properties[0].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 4), layouts[0].properties[1].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 8), layouts[0].properties[2].fixed_offset);
    for (layouts[0].properties) |property_layout| {
        try std.testing.expectEqual(@as(?usize, 4), property_layout.fixed_width);
    }
}

test "three f64 properties: 24-byte fixed record with offsets 0/8/16" {
    const properties = [_]Property{
        Property.scalar("x", .f64),
        Property.scalar("y", .f64),
        Property.scalar("z", .f64),
    };
    const elements = [_]Element{scalarElement("vertex", 10, &properties)};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    try std.testing.expectEqual(@as(?usize, 24), layouts[0].fixed_record_size);
    try std.testing.expectEqual(@as(?usize, 0), layouts[0].properties[0].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 8), layouts[0].properties[1].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 16), layouts[0].properties[2].fixed_offset);
}

test "XYZRGB: 15-byte fixed record" {
    const properties = [_]Property{
        Property.scalar("x", .f32),
        Property.scalar("y", .f32),
        Property.scalar("z", .f32),
        Property.scalar("red", .u8),
        Property.scalar("green", .u8),
        Property.scalar("blue", .u8),
    };
    const elements = [_]Element{scalarElement("vertex", 4, &properties)};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    try std.testing.expectEqual(@as(?usize, 15), layouts[0].fixed_record_size);
    const expected_offsets = [_]usize{ 0, 4, 8, 12, 13, 14 };
    for (expected_offsets, 0..) |offset, i| {
        try std.testing.expectEqual(@as(?usize, offset), layouts[0].properties[i].fixed_offset);
    }
    try std.testing.expectEqual(@as(u64, 60), layouts[0].fixed_body_size.?);
    try std.testing.expectEqual(@as(?u64, 0), layouts[0].body_start_offset);
}

test "empty property list: zero-byte fixed record" {
    const elements = [_]Element{scalarElement("empty", 7, &.{})};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    try std.testing.expectEqual(@as(?usize, 0), layouts[0].fixed_record_size);
    try std.testing.expectEqual(@as(usize, 0), layouts[0].minimum_record_size);
    try std.testing.expectEqual(@as(?u64, 0), layouts[0].fixed_body_size);
    try std.testing.expectEqual(@as(usize, 0), layouts[0].properties.len);
}

test "scalar followed by list: variable record, scalar offset fixed" {
    const properties = [_]Property{
        Property.scalar("confidence", .f32),
        Property.list("neighbors", .u8, .i32),
    };
    const elements = [_]Element{scalarElement("vertex", 3, &properties)};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    try std.testing.expectEqual(@as(?usize, null), layouts[0].fixed_record_size);
    // minimum: 4 (f32) + 1 (uchar count prefix)
    try std.testing.expectEqual(@as(usize, 5), layouts[0].minimum_record_size);

    try std.testing.expectEqual(@as(?usize, 0), layouts[0].properties[0].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 4), layouts[0].properties[0].fixed_width);

    try std.testing.expectEqual(@as(?usize, 4), layouts[0].properties[1].fixed_offset);
    try std.testing.expectEqual(@as(?usize, null), layouts[0].properties[1].fixed_width);
}

test "list followed by scalar: scalar offset unresolved, width known" {
    const properties = [_]Property{
        Property.scalar("confidence", .f32),
        Property.list("neighbors", .u8, .i32),
        Property.scalar("timestamp", .f64),
    };
    const elements = [_]Element{scalarElement("vertex", 3, &properties)};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    // minimum: 4 + 1 + 8 = 13.
    try std.testing.expectEqual(@as(usize, 13), layouts[0].minimum_record_size);
    try std.testing.expectEqual(@as(?usize, null), layouts[0].fixed_record_size);

    try std.testing.expectEqual(@as(?usize, 0), layouts[0].properties[0].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 4), layouts[0].properties[1].fixed_offset);
    try std.testing.expectEqual(@as(?usize, null), layouts[0].properties[2].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 8), layouts[0].properties[2].fixed_width);
}

test "multiple lists: variable record" {
    const properties = [_]Property{
        Property.list("a", .u8, .i32),
        Property.list("b", .u8, .f64),
    };
    const elements = [_]Element{scalarElement("vertex", 3, &properties)};

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    defer std.testing.allocator.free(layouts[0].properties);

    try std.testing.expectEqual(@as(?usize, null), layouts[0].fixed_record_size);
    try std.testing.expectEqual(@as(usize, 2), layouts[0].minimum_record_size); // 1 + 1 count prefixes
    try std.testing.expectEqual(@as(?usize, 0), layouts[0].properties[0].fixed_offset);
    // Once the first list is seen, later offsets are unresolved — including
    // the second list's own.
    try std.testing.expectEqual(@as(?usize, null), layouts[0].properties[1].fixed_offset);
}

test "body offsets chain through fixed elements but stop at variable ones" {
    const vertex_properties = [_]Property{
        Property.scalar("x", .f32),
        Property.scalar("y", .f32),
        Property.scalar("z", .f32),
    };
    const face_properties = [_]Property{
        Property.list("vertex_indices", .u8, .i32),
    };
    const edge_properties = [_]Property{
        Property.scalar("vertex1", .i32),
        Property.scalar("vertex2", .i32),
    };

    const elements = [_]Element{
        scalarElement("vertex", 1000, &vertex_properties), // fixed: 1000 * 12
        scalarElement("face", 500, &face_properties), // variable
        scalarElement("edge", 100, &edge_properties), // fixed: 100 * 8
    };

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    for (layouts) |l| std.testing.allocator.free(l.properties);

    // vertex starts at 0, body 12000 bytes.
    try std.testing.expectEqual(@as(?u64, 0), layouts[0].body_start_offset);
    try std.testing.expectEqual(@as(u64, 12000), layouts[0].fixed_body_size.?);

    // face starts right after the vertex body; its size is unknown.
    try std.testing.expectEqual(@as(?u64, 12000), layouts[1].body_start_offset);
    try std.testing.expectEqual(@as(?u64, null), layouts[1].fixed_body_size);

    // edge's start cannot be known from the header alone.
    try std.testing.expectEqual(@as(?u64, null), layouts[2].body_start_offset);
    try std.testing.expectEqual(@as(?usize, 8), layouts[2].fixed_record_size);
    try std.testing.expectEqual(@as(u64, 800), layouts[2].fixed_body_size.?);
}

test "variable first element: everything after it is unresolved" {
    const list_properties = [_]Property{
        Property.list("indices", .u8, .i32),
    };
    const fixed_properties = [_]Property{
        Property.scalar("x", .f64),
    };
    const elements = [_]Element{
        scalarElement("face", 10, &list_properties),
        scalarElement("vertex", 10, &fixed_properties),
    };

    const layouts = try compile(&elements);
    defer std.testing.allocator.free(layouts);
    for (layouts) |l| std.testing.allocator.free(l.properties);

    try std.testing.expectEqual(@as(?u64, 0), layouts[0].body_start_offset);
    try std.testing.expectEqual(@as(?u64, null), layouts[1].body_start_offset);
    try std.testing.expectEqual(@as(?usize, 8), layouts[1].fixed_record_size);
}

test "declared count overflow in body-size multiplication is NumericOverflow" {
    const properties = [_]Property{
        Property.scalar("x", .f64),
    };
    const elements = [_]Element{
        .{ .name = "vertex", .count = std.math.maxInt(u64), .properties = &properties },
    };

    try std.testing.expectError(error.NumericOverflow, compile(&elements));
}

test "parsed header layouts match manually compiled layouts" {
    // Parse the canonical example header...
    const bytes =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
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

    var reader: std.Io.Reader = .fixed(bytes);
    var storage = try internals.header_parser.parseHeader(
        std.testing.allocator,
        &reader,
        .{},
    );
    defer storage.deinit();

    // ...and compile the same schema by hand.
    const vertex_properties = [_]Property{
        Property.scalar("x", .f64),
        Property.scalar("y", .f64),
        Property.scalar("z", .f64),
        Property.scalar("red", .u8),
        Property.scalar("green", .u8),
        Property.scalar("blue", .u8),
    };
    const face_properties = [_]Property{
        Property.list("vertex_indices", .u8, .i32),
    };
    const elements = [_]Element{
        scalarElement("vertex", 1000000, &vertex_properties),
        scalarElement("face", 500000, &face_properties),
    };
    const manual = try compile(&elements);

    const parsed = storage.layouts;
    try std.testing.expectEqual(manual.len, parsed.len);
    for (manual, parsed) |*m, *p| {
        try std.testing.expectEqual(m.element_index, p.element_index);
        try std.testing.expectEqual(m.fixed_record_size, p.fixed_record_size);
        try std.testing.expectEqual(m.minimum_record_size, p.minimum_record_size);
        try std.testing.expectEqual(m.body_start_offset, p.body_start_offset);
        try std.testing.expectEqual(m.fixed_body_size, p.fixed_body_size);
        try std.testing.expectEqual(m.properties.len, p.properties.len);
        for (m.properties, p.properties) |mp, pp| {
            try std.testing.expectEqual(mp.property_index, pp.property_index);
            try std.testing.expectEqual(mp.fixed_offset, pp.fixed_offset);
            try std.testing.expectEqual(mp.fixed_width, pp.fixed_width);
        }
    }

    // The spec example's headline numbers.
    try std.testing.expectEqual(@as(?usize, 27), parsed[0].fixed_record_size);
    try std.testing.expectEqual(@as(?usize, null), parsed[1].fixed_record_size);

    // Free the manually compiled allocations after comparison.
    for (manual) |l| std.testing.allocator.free(l.properties);
    std.testing.allocator.free(manual);
}
