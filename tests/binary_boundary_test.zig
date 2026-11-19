//! Phase 10: allocation-free variable-record boundary discovery.
const std = @import("std");
const internals = @import("zply_internals");
const scan = internals.binary_boundary;
const Property = internals.property.Property;
const Element = internals.element.Element;
const Header = internals.header.Header;
const Layout = internals.layout.ElementLayout;

const limits: scan.Limits = .{ .max_record_bytes = 1024, .max_list_items_per_record = 128 };

fn compile(properties: []const Property) !struct { layouts: []Layout } {
    const elements = [_]Element{.{ .name = "custom", .count = 5, .properties = properties }};
    const header = Header{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    return .{ .layouts = try internals.layout.compileSchema(std.testing.allocator, &header) };
}
fn freeLayouts(layouts: []Layout) void {
    for (layouts) |layout| std.testing.allocator.free(layout.properties);
    std.testing.allocator.free(layouts);
}
fn expectComplete(result: scan.ScanResult, width: usize, total_items: usize) !void {
    switch (result) {
        .complete => |complete| {
            try std.testing.expectEqual(width, complete.byte_length);
            try std.testing.expectEqual(total_items, complete.total_list_items);
        },
        .incomplete => return error.TestUnexpectedResult,
    }
}
fn expectIncomplete(result: scan.ScanResult, pi: usize, stage: scan.Stage, required: usize) !void {
    switch (result) {
        .complete => return error.TestUnexpectedResult,
        .incomplete => |part| {
            try std.testing.expectEqual(pi, part.property_index);
            try std.testing.expectEqual(stage, part.stage);
            try std.testing.expectEqual(required, part.required_total);
        },
    }
}

test "Phase 10 compiled variable operations preserve count and item types" {
    const props = [_]Property{
        Property.scalar("confidence", .f32),
        Property.list("neighbors", .u8, .i32),
        Property.scalar("timestamp", .f64),
        Property.list("weights", .u16, .f32),
    };
    const compiled = try compile(&props);
    defer freeLayouts(compiled.layouts);
    const layout = &compiled.layouts[0];
    try std.testing.expectEqual(@as(?usize, null), layout.fixed_record_size);
    try std.testing.expectEqual(@as(usize, 15), layout.minimum_record_size);
    try std.testing.expectEqual(@as(?usize, null), layout.properties[2].fixed_offset);
    try std.testing.expectEqual(internals.types.IntegerType.u8, layout.properties[1].binary_op.?.list.count_type);
    try std.testing.expectEqual(internals.types.ScalarType.i32, layout.properties[1].binary_op.?.list.item_type);
    try std.testing.expectEqual(internals.types.IntegerType.u16, layout.properties[3].binary_op.?.list.count_type);
    try std.testing.expectEqual(@as(usize, 4), layout.properties[3].binary_op.?.list.item_width);
}

test "Phase 10 mixed scalar and two-list boundary scanning in both byte orders" {
    const props = [_]Property{
        Property.scalar("confidence", .f32),
        Property.list("neighbors", .u8, .i32),
        Property.scalar("timestamp", .f64),
        Property.list("weights", .u16, .f32),
    };
    const compiled = try compile(&props);
    defer freeLayouts(compiled.layouts);
    const layout = &compiled.layouts[0];

    const little = [_]u8{
        0, 0, 128, 63, // f32 confidence = 1
        3, // u8 neighbor count
        10,
        0,
        0,
        0,
        11,
        0,
        0,
        0,
        12,
        0,
        0,
        0,
        0, 0, 0, 0, 0, 0, 0, 64, // f64 timestamp = 2
        2, 0, // u16 weights count
        0, 0, 128, 63, 0, 0, 0, 128, // float values
    };
    const big = [_]u8{
        63,  128, 0, 0,
        3,   0,   0, 0,
        10,  0,   0, 0,
        11,  0,   0, 0,
        12,  64,  0, 0,
        0,   0,   0, 0,
        0,   0,   2, 63,
        128, 0,   0, 128,
        0,   0,   0,
    };
    try std.testing.expectEqual(@as(usize, 35), little.len);
    try std.testing.expectEqual(little.len, big.len);

    inline for (.{ .little, .big }) |endian| {
        const bytes: []const u8 = if (endian == .little) &little else &big;
        var counts = [_]usize{ 0, 0, 0, 0 };
        try expectComplete(try scan.scanRecord(layout, endian, bytes, limits, &counts), 35, 5);
        try std.testing.expectEqualSlices(usize, &.{ 0, 3, 0, 2 }, &counts);
        // A scalar, count, payload, following scalar, and second count
        // each request exactly the missing structural bytes.
        try expectIncomplete(try scan.scanRecord(layout, endian, bytes[0..2], limits, null), 0, .scalar, 4);
        try expectIncomplete(try scan.scanRecord(layout, endian, bytes[0..4], limits, null), 1, .list_count, 5);
        try expectIncomplete(try scan.scanRecord(layout, endian, bytes[0..8], limits, null), 1, .list_items, 17);
        try expectIncomplete(try scan.scanRecord(layout, endian, bytes[0..20], limits, null), 2, .scalar, 25);
        try expectIncomplete(try scan.scanRecord(layout, endian, bytes[0..26], limits, null), 3, .list_count, 27);
        try expectIncomplete(try scan.scanRecord(layout, endian, bytes[0..27], limits, null), 3, .list_items, 35);
        try std.testing.expectError(error.InvalidLayout, scan.scanRecord(layout, endian, bytes, limits, counts[0..2]));
    }
}

test "Phase 10 list boundaries distinguish triangle quad and empty list" {
    const props = [_]Property{Property.list("indices", .u8, .i32)};
    const compiled = try compile(&props);
    defer freeLayouts(compiled.layouts);
    const layout = &compiled.layouts[0];
    const records = [_]u8{
        3, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0,
        4, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0,
        3, 0, 0, 0, 0,
    };
    var offset: usize = 0;
    const widths = [_]usize{ 13, 17, 1 };
    for (widths) |width| {
        const result = try scan.scanRecord(layout, .little, records[offset..], limits, null);
        try expectComplete(result, width, (width - 1) / 4);
        offset += width;
    }
    try std.testing.expectEqual(records.len, offset);
    try expectIncomplete(try scan.scanRecord(layout, .little, &.{}, limits, null), 0, .list_count, 1);
}

test "Phase 10 negative list count and oversize count fail before payload access" {
    const props = [_]Property{Property.list("items", .i16, .f64)};
    const compiled = try compile(&props);
    defer freeLayouts(compiled.layouts);
    const layout = &compiled.layouts[0];
    try std.testing.expectError(error.NegativeListCount, scan.scanRecord(layout, .little, &.{ 0xff, 0xff }, limits, null));
    try std.testing.expectError(error.ListTooLarge, scan.scanRecord(layout, .big, &.{ 0, 129 }, limits, null));
    try std.testing.expectError(error.RecordTooLarge, scan.scanRecord(layout, .big, &.{ 0, 128 }, .{
        .max_record_bytes = 1000,
        .max_list_items_per_record = 128,
    }, null));
    try expectIncomplete(try scan.scanRecord(layout, .little, &.{ 0x02, 0x00 }, limits, null), 0, .list_items, 18);
}
