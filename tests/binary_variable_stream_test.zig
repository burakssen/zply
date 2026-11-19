//! Phase 10 incremental variable-width binary reader regression tests.
const std = @import("std");
const internals = @import("zply_internals");
const stream = internals.binary_variable;
const boundary = internals.binary_boundary;
const support = @import("streaming_support.zig");
const Property = internals.property.Property;
const Element = internals.element.Element;
const Header = internals.header.Header;
const ElementLayout = internals.layout.ElementLayout;

fn compile(properties: []const Property) ![]ElementLayout {
    const elements = [_]Element{.{ .name = "items", .count = 2, .properties = properties }};
    const header = Header{
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

const limits: boundary.Limits = .{ .max_record_bytes = 4096, .max_list_items_per_record = 256 };

test "Phase 10 variable reader handles fragmented scalar count payload and second record" {
    const props = [_]Property{
        Property.scalar("confidence", .f32),
        Property.list("indices", .u16, .i32),
        Property.scalar("timestamp", .f64),
    };
    const layouts = try compile(&props);
    defer freeLayouts(layouts);

    const little = [_]u8{
        0, 0, 128, 63, // 1.0f
        3,  0, // u16 count
        10, 0,
        0,  0,
        11, 0,
        0,  0,
        12, 0,
        0,  0,
        0, 0, 0,   0,  0, 0, 0, 64, // f64 scalar after list
        0, 0, 128, 63,
        0, 0, // empty second list
        0, 0,
        0, 0,
        0, 0,
        0, 64,
        0xaa, 0xbb, // must remain untouched
    };
    const big = [_]u8{
        63,   128,  0,  0,
        0,    3,    0,  0,
        0,    10,   0,  0,
        0,    11,   0,  0,
        0,    12,   64, 0,
        0,    0,    0,  0,
        0,    0,    63, 128,
        0,    0,    0,  0,
        64,   0,    0,  0,
        0,    0,    0,  0,
        0xaa, 0xbb,
    };
    try std.testing.expectEqual(@as(usize, 42), little.len);
    try std.testing.expectEqual(little.len, big.len);

    const patterns = [_][]const usize{ &.{1}, &.{2}, &.{3}, &.{7}, &.{64}, &.{ 1, 7, 2, 3 } };
    inline for (.{ .little, .big }) |endian| {
        const bytes: []const u8 = if (endian == .little) &little else &big;
        for (patterns) |pattern| {
            var source = support.FragmentingReader.init(bytes, pattern, 0);
            var reader: stream.Reader = .{};
            defer reader.deinit(std.testing.allocator);

            const first = try reader.readRecord(std.testing.allocator, source.reader(), &layouts[0], endian, limits);
            try std.testing.expectEqual(@as(u64, 0), first.body_offset);
            try std.testing.expectEqual(@as(u64, 0), first.record_index);
            try std.testing.expectEqual(@as(usize, 3), first.total_list_items);
            try std.testing.expectEqualSlices(u8, bytes[0..26], first.bytes);
            try std.testing.expectEqual(@as(u64, 26), reader.completed_body_bytes);

            const second = try reader.readRecord(std.testing.allocator, source.reader(), &layouts[0], endian, limits);
            try std.testing.expectEqual(@as(u64, 26), second.body_offset);
            try std.testing.expectEqual(@as(u64, 1), second.record_index);
            try std.testing.expectEqual(@as(usize, 0), second.total_list_items);
            try std.testing.expectEqualSlices(u8, bytes[26..40], second.bytes);
            try std.testing.expectEqual(@as(u64, 40), reader.body_bytes_consumed);
            try std.testing.expectEqual(@as(u64, 40), reader.completed_body_bytes);
            try std.testing.expectEqual(@as(u64, 2), reader.completed_record_count);
            try std.testing.expectEqual(@as(u8, 0xaa), try source.reader().takeByte());
            try std.testing.expectEqual(@as(u8, 0xbb), try source.reader().takeByte());
        }
    }
}

test "Phase 10 variable reader classifies truncated list counts payload and following scalar" {
    const props = [_]Property{
        Property.list("items", .u16, .i32),
        Property.scalar("timestamp", .f64),
    };
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    const record = [_]u8{
        2,  0, // count (2 items)
        10, 0,
        0,  0,
        20, 0,
        0,  0,
        0,  0,
        0,  0,
        0,  0,
        0,  64,
    };
    for (0..record.len) |prefix| {
        var source: std.Io.Reader = .fixed(record[0..prefix]);
        var reader: stream.Reader = .{};
        defer reader.deinit(std.testing.allocator);
        const expected = if (prefix < 2) error.TruncatedListCount else if (prefix < 10) error.TruncatedListPayload else error.TruncatedRecord;
        try std.testing.expectError(expected, reader.readRecord(std.testing.allocator, &source, &layouts[0], .little, limits));
        try std.testing.expect(reader.failed);
        try std.testing.expect(reader.in_progress);
        try std.testing.expectEqual(@as(u64, @intCast(prefix)), reader.body_bytes_consumed);
        try std.testing.expectEqual(@as(u64, 0), reader.completed_body_bytes);
        try std.testing.expectEqual(@as(u64, 0), reader.completed_record_count);
        try std.testing.expectError(error.InvalidReaderState, reader.readRecord(std.testing.allocator, &source, &layouts[0], .little, limits));
    }
}

test "Phase 10 variable reader resumes a partially consumed list after memory pressure" {
    const props = [_]Property{Property.list("items", .u8, .u8)};
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    var data: [202]u8 = undefined;
    data[0] = 200;
    for (data[1..201], 0..) |*value, i| value.* = @intCast(i % 251);
    data[201] = 0; // second record: empty list

    var backing: [8192]u8 = undefined;
    var limited = std.heap.FixedBufferAllocator.init(backing[0..96]);
    var source: std.Io.Reader = .fixed(&data);
    var reader: stream.Reader = .{};
    defer reader.deinit(limited.allocator());

    try std.testing.expectError(error.OutOfMemory, reader.readRecord(limited.allocator(), &source, &layouts[0], .little, limits));
    try std.testing.expect(reader.in_progress);
    try std.testing.expect(!reader.failed);
    try std.testing.expect(reader.scratch.items.len > 1);
    try std.testing.expect(reader.scratch.items.len < 201);
    try std.testing.expectEqual(@as(u64, @intCast(reader.scratch.items.len)), reader.body_bytes_consumed);
    try std.testing.expectEqual(@as(u64, 0), reader.completed_record_count);
    try std.testing.expectEqual(boundary.Stage.list_items, reader.requirement.?.stage);

    limited.buffer = backing[0..];
    const first = try reader.readRecord(limited.allocator(), &source, &layouts[0], .little, limits);
    try std.testing.expectEqualSlices(u8, data[0..201], first.bytes);
    try std.testing.expectEqual(@as(u64, 0), first.body_offset);
    try std.testing.expectEqual(@as(usize, 200), first.total_list_items);
    try std.testing.expectEqual(@as(u64, 201), reader.completed_body_bytes);
    const second = try reader.readRecord(limited.allocator(), &source, &layouts[0], .little, limits);
    try std.testing.expectEqual(@as(u64, 201), second.body_offset);
    try std.testing.expectEqual(@as(usize, 0), second.total_list_items);
    try std.testing.expectEqual(@as(u64, 2), reader.completed_record_count);
}

test "Phase 10 variable reader allocates before consuming the first byte" {
    const props = [_]Property{Property.list("items", .u8, .u8)};
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    const data = [_]u8{0};
    var backing: [512]u8 = undefined;
    var limited = std.heap.FixedBufferAllocator.init(backing[0..0]);
    var source: std.Io.Reader = .fixed(&data);
    var reader: stream.Reader = .{};
    defer reader.deinit(limited.allocator());
    try std.testing.expectError(error.OutOfMemory, reader.readRecord(limited.allocator(), &source, &layouts[0], .little, limits));
    try std.testing.expectEqual(@as(u64, 0), reader.body_bytes_consumed);
    try std.testing.expectEqual(@as(usize, 0), reader.scratch.items.len);
    limited.buffer = backing[0..];
    const result = try reader.readRecord(limited.allocator(), &source, &layouts[0], .little, limits);
    try std.testing.expectEqualSlices(u8, &data, result.bytes);
    try std.testing.expectEqual(@as(u64, 1), reader.completed_body_bytes);
}

test "Phase 10 oversized counts are rejected before reading any payload" {
    const props = [_]Property{Property.list("items", .u32, .f64)};
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    const data = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xaa };
    var source: std.Io.Reader = .fixed(&data);
    var reader: stream.Reader = .{};
    defer reader.deinit(std.testing.allocator);
    try std.testing.expectError(error.ListTooLarge, reader.readRecord(std.testing.allocator, &source, &layouts[0], .little, limits));
    try std.testing.expect(reader.failed);
    try std.testing.expectEqual(@as(u64, 4), reader.body_bytes_consumed);
    try std.testing.expectEqual(@as(u8, 0xaa), try source.takeByte());
}

test "Phase 10 variable reader distinguishes source failure from truncation" {
    const props = [_]Property{Property.list("items", .u16, .i32)};
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    const data = [_]u8{ 3, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 };
    var source = support.FailingReader.init(&data, 7);
    var reader: stream.Reader = .{};
    defer reader.deinit(std.testing.allocator);
    try std.testing.expectError(error.ReadFailed, reader.readRecord(std.testing.allocator, source.reader(), &layouts[0], .little, limits));
    try std.testing.expect(reader.failed);
    try std.testing.expect(reader.in_progress);
    try std.testing.expectEqual(@as(u64, 7), reader.body_bytes_consumed);
    try std.testing.expectEqual(@as(u64, 0), reader.completed_record_count);
}

test "Phase 10 negative binary list count is terminal before payload" {
    const props = [_]Property{Property.list("items", .i16, .i32)};
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    const data = [_]u8{ 0xff, 0xff, 0xaa };
    var source: std.Io.Reader = .fixed(&data);
    var reader: stream.Reader = .{};
    defer reader.deinit(std.testing.allocator);
    try std.testing.expectError(error.NegativeListCount, reader.readRecord(std.testing.allocator, &source, &layouts[0], .little, limits));
    try std.testing.expectEqual(@as(u64, 2), reader.body_bytes_consumed);
    try std.testing.expectEqual(@as(u8, 0xaa), try source.takeByte());
}

test "Phase 10 buffered input copies large binary payloads in bounded spans without reading ahead" {
    const properties = [_]Property{Property.list("items", .u16, .u8)};
    const layouts = try compile(&properties);
    defer freeLayouts(layouts);
    const item_count: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, item_count + 2 + 1);
    defer std.testing.allocator.free(data);
    for (data[2 .. 2 + item_count], 0..) |*value, i| value.* = @intCast(i % 251);
    data[data.len - 1] = 0xa5;

    inline for (.{ .little, .big }) |endian| {
        std.mem.writeInt(u16, data[0..2], @intCast(item_count), endian);
        const generous: boundary.Limits = .{
            .max_record_bytes = 16 * 1024,
            .max_list_items_per_record = 10_000,
        };
        var source: std.Io.Reader = .fixed(data);
        var reader: stream.Reader = .{};
        defer reader.deinit(std.testing.allocator);
        const view = try reader.readRecord(std.testing.allocator, &source, &layouts[0], endian, generous);
        try std.testing.expectEqual(@as(usize, item_count + 2), view.bytes.len);
        try std.testing.expectEqualSlices(u8, data[0 .. item_count + 2], view.bytes);
        try std.testing.expectEqual(item_count, view.total_list_items);
        try std.testing.expectEqual(@as(u64, item_count + 2), reader.body_bytes_consumed);
        // The staged payload uses a few bounded copies, not one takeByte per byte.
        try std.testing.expect(reader.copied_spans < 256);
        try std.testing.expectEqual(@as(u8, 0xa5), try source.takeByte());
    }
}

test "Phase 10 bulk staging tracks the exact truncated prefix through fragmented reads" {
    const properties = [_]Property{Property.list("items", .u16, .u8)};
    const layouts = try compile(&properties);
    defer freeLayouts(layouts);
    const item_count: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, item_count + 2);
    defer std.testing.allocator.free(data);
    std.mem.writeInt(u16, data[0..2], @intCast(item_count), .little);
    @memset(data[2..], 0x7e);
    const generous: boundary.Limits = .{
        .max_record_bytes = 16 * 1024,
        .max_list_items_per_record = 10_000,
    };
    for ([_]usize{ 2, 7, 32, 4095, 8189 }) |prefix| {
        var source = support.FragmentingReader.init(data[0..prefix], &.{ 1, 3, 7, 2 }, 0);
        var reader: stream.Reader = .{};
        defer reader.deinit(std.testing.allocator);
        try std.testing.expectError(error.TruncatedListPayload, reader.readRecord(
            std.testing.allocator,
            source.reader(),
            &layouts[0],
            .little,
            generous,
        ));
        try std.testing.expect(reader.failed);
        try std.testing.expectEqual(@as(u64, @intCast(prefix)), reader.body_bytes_consumed);
        try std.testing.expectEqualSlices(u8, data[0..prefix], reader.scratch.items);
        try std.testing.expectEqual(@as(u64, 0), reader.completed_record_count);
    }
}
