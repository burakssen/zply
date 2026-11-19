//! Phase 10 variable-width binary record-aligned chunk tests.
const std = @import("std");
const internals = @import("zply_internals");
const chunks = internals.binary_chunk_builder;
const support = @import("streaming_support.zig");
const Property = internals.property.Property;
const Element = internals.element.Element;
const Header = internals.header.Header;
const ElementLayout = internals.layout.ElementLayout;

fn compile(properties: []const Property) ![]ElementLayout {
    const elements = [_]Element{.{ .name = "custom", .count = 3, .properties = properties }};
    const header: Header = .{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    return internals.layout.compileSchema(std.testing.allocator, &header);
}

fn freeLayouts(layouts: []ElementLayout) void {
    for (layouts) |layout| std.testing.allocator.free(layout.properties);
    std.testing.allocator.free(layouts);
}

const props = [_]Property{
    Property.list("neighbors", .u8, .i32),
    Property.scalar("confidence", .f32),
    Property.list("weights", .u16, .u8),
};
const limits: internals.binary_boundary.Limits = .{
    .max_record_bytes = 4096,
    .max_list_items_per_record = 256,
};

const little = [_]u8{
    // r0: neighbors [10,11], confidence 1.0f, weights [7,8,9]
    2, 10, 0, 0, 0,  11, 0, 0, 0, 0,  0, 128, 63, 3, 0, 7,  8,  9,
    // r1: empty neighbors, confidence 2.0f, one weight
    0, 0,  0, 0, 64, 1,  0, 5,
    // r2: neighbors [12], confidence 3.0f, no weights
    1, 12, 0, 0,   0,  0, 0, 64, 64, 0,
    0,
    0xfd, // trailing data must remain unread
};
const big = [_]u8{
    2, 0,    0, 0, 10, 0, 0, 0, 11, 63, 128, 0, 0,  0,  3,  7, 8, 9,
    0, 64,   0, 0, 0,  0, 1, 5, 1,  0,  0,   0, 12, 64, 64, 0, 0, 0,
    0, 0xfd,
};

test "Phase 10 binary chunks split on records and preserve per-property list totals" {
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    try std.testing.expectEqual(@as(usize, 38), little.len);
    try std.testing.expectEqual(little.len, big.len);
    const patterns = [_][]const usize{ &.{1}, &.{ 3, 1, 7, 2 }, &.{64} };
    inline for (.{ .little, .big }) |endian| {
        const bytes: []const u8 = if (endian == .little) &little else &big;
        for (patterns) |pattern| {
            var source = support.FragmentingReader.init(bytes, pattern, 0);
            var builder: chunks.Builder = .{};
            defer builder.deinit(std.testing.allocator);

            const first = (try builder.fill(std.testing.allocator, source.reader(), &layouts[0], endian, limits, 24, 0, 3)).?;
            try std.testing.expectEqual(@as(usize, 0), first.element_index);
            try std.testing.expectEqual(@as(u64, 0), first.first_record);
            try std.testing.expectEqual(@as(u64, 0), first.first_body_byte_offset);
            try std.testing.expectEqual(@as(usize, 1), first.record_count);
            try std.testing.expectEqualSlices(u8, bytes[0..18], first.bytes);
            try std.testing.expectEqualSlices(usize, &.{ 0, 18 }, first.offsets);
            try std.testing.expectEqualSlices(usize, &.{ 2, 0, 3 }, first.list_item_totals);
            try std.testing.expect(builder.pending); // record 1 was read but not dropped
            try std.testing.expectEqual(@as(u64, 2), builder.record_reader.completed_record_count);
            try std.testing.expectEqualSlices(u8, bytes[0..18], (try builder.fill(std.testing.allocator, source.reader(), &layouts[0], endian, limits, 24, 0, 3)).?.bytes);
            builder.consume();

            const second = (try builder.fill(std.testing.allocator, source.reader(), &layouts[0], endian, limits, 24, 1, 2)).?;
            try std.testing.expectEqual(@as(u64, 1), second.first_record);
            try std.testing.expectEqual(@as(u64, 18), second.first_body_byte_offset);
            try std.testing.expectEqual(@as(usize, 2), second.record_count);
            try std.testing.expectEqualSlices(u8, bytes[18..37], second.bytes);
            try std.testing.expectEqualSlices(usize, &.{ 0, 8, 19 }, second.offsets);
            try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1 }, second.list_item_totals);
            try std.testing.expectEqual(@as(u64, 37), builder.record_reader.body_bytes_consumed);
            try std.testing.expectEqual(@as(u64, 3), builder.record_reader.completed_record_count);
            builder.consume();
            try std.testing.expect((try builder.fill(std.testing.allocator, source.reader(), &layouts[0], endian, limits, 24, 3, 0)) == null);
            try std.testing.expectEqual(@as(u8, 0xfd), try source.reader().takeByte());
        }
    }
}

test "Phase 10 binary chunks allow an oversized first record and never consume next element" {
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    var source: std.Io.Reader = .fixed(&little);
    var builder: chunks.Builder = .{};
    defer builder.deinit(std.testing.allocator);

    const first = (try builder.fill(std.testing.allocator, &source, &layouts[0], .little, limits, 4, 8, 1)).?;
    try std.testing.expectEqual(@as(usize, 1), first.record_count);
    try std.testing.expectEqual(@as(usize, 18), first.bytes.len);
    try std.testing.expectEqual(@as(u64, 8), first.first_record);
    builder.consume();
    try std.testing.expectEqual(@as(u8, 0), try source.takeByte()); // next record's first count
}

test "Phase 10 binary chunks resume after memory pressure while preserving completed record" {
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    var backing: [8192]u8 = undefined;
    var limited = std.heap.FixedBufferAllocator.init(backing[0..80]);
    var source: std.Io.Reader = .fixed(&little);
    var builder: chunks.Builder = .{};
    defer builder.deinit(limited.allocator());

    // The limited budget can fail at an arbitrary allocation site, possibly
    // after some reader bytes have been consumed. Retrying is exact-once.
    try std.testing.expectError(error.OutOfMemory, builder.fill(limited.allocator(), &source, &layouts[0], .little, limits, 24, 0, 3));
    const before = builder.record_reader.body_bytes_consumed;
    try std.testing.expect(before <= 37);
    limited.buffer = backing[0..];

    const first = (try builder.fill(limited.allocator(), &source, &layouts[0], .little, limits, 24, 0, 3)).?;
    try std.testing.expectEqualSlices(u8, little[0..18], first.bytes);
    builder.consume();
    const second = (try builder.fill(limited.allocator(), &source, &layouts[0], .little, limits, 24, 1, 2)).?;
    try std.testing.expectEqualSlices(u8, little[18..37], second.bytes);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1 }, second.list_item_totals);
    builder.consume();
    try std.testing.expectEqual(@as(u64, 37), builder.record_reader.completed_body_bytes);
}

test "Phase 10 binary chunks reject a changed layout while retaining a pending record" {
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    var source: std.Io.Reader = .fixed(&little);
    var builder: chunks.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    _ = (try builder.fill(std.testing.allocator, &source, &layouts[0], .little, limits, 24, 0, 3)).?;
    builder.consume();
    const other = ElementLayout{
        .element_index = 1,
        .fixed_record_size = null,
        .minimum_record_size = layouts[0].minimum_record_size,
        .body_start_offset = null,
        .fixed_body_size = null,
        .properties = layouts[0].properties,
    };
    try std.testing.expectError(error.InvalidBuilderState, builder.fill(std.testing.allocator, &source, &other, .little, limits, 24, 0, 2));
    const recovered = (try builder.fill(std.testing.allocator, &source, &layouts[0], .little, limits, 24, 1, 2)).?;
    try std.testing.expectEqualSlices(u8, little[18..37], recovered.bytes);
}

test "Phase 10 binary chunk byte offsets cross variable element boundaries" {
    const first_props = [_]Property{Property.list("indices", .u8, .u8)};
    const second_props = [_]Property{
        Property.scalar("marker", .f32),
        Property.list("items", .u16, .u8),
    };
    const elements = [_]Element{
        .{ .name = "faces", .count = 1, .properties = &first_props },
        .{ .name = "custom", .count = 1, .properties = &second_props },
    };
    const header: Header = .{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    const layouts = try internals.layout.compileSchema(std.testing.allocator, &header);
    defer freeLayouts(layouts);
    const body = [_]u8{
        2, 6, 7, // element 0: list of two bytes
        0,    0, 128, 63, 1, 0, 8, // element 1: scalar then one list item
        0xee,
    };
    var source: std.Io.Reader = .fixed(&body);
    var builder: chunks.Builder = .{};
    defer builder.deinit(std.testing.allocator);

    const face = (try builder.fill(std.testing.allocator, &source, &layouts[0], .little, limits, 2, 0, 1)).?;
    try std.testing.expectEqual(@as(usize, 3), face.bytes.len);
    try std.testing.expectEqual(@as(u64, 0), face.first_body_byte_offset);
    try std.testing.expectEqualSlices(usize, &.{2}, face.list_item_totals);
    builder.consume();

    const custom = (try builder.fill(std.testing.allocator, &source, &layouts[1], .little, limits, 2, 0, 1)).?;
    try std.testing.expectEqual(@as(usize, 7), custom.bytes.len);
    try std.testing.expectEqual(@as(u64, 3), custom.first_body_byte_offset);
    try std.testing.expectEqual(@as(u64, 0), custom.first_record);
    try std.testing.expectEqual(@as(usize, 1), custom.element_index);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, custom.list_item_totals);
    builder.consume();
    try std.testing.expectEqual(@as(u8, 0xee), try source.takeByte());
}

test "Phase 10 chunk offsets can start after externally consumed fixed-width body bytes" {
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    // The preceding fixed-width element was consumed by a different producer.
    var source: std.Io.Reader = .fixed(&little);
    var builder: chunks.Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.synchronizeBodyOffset(128);
    const chunk = (try builder.fill(std.testing.allocator, &source, &layouts[0], .little, limits, 4, 0, 1)).?;
    try std.testing.expectEqual(@as(u64, 128), chunk.first_body_byte_offset);
    try std.testing.expectEqual(@as(u64, 146), builder.record_reader.body_bytes_consumed);
    try std.testing.expectError(error.InvalidBuilderState, builder.synchronizeBodyOffset(200));
    builder.consume();
    try std.testing.expectError(error.InvalidBuilderState, builder.synchronizeBodyOffset(100));
}
