//! Phase 10 preflight and allocation-free typed binary-list decoding.
const std = @import("std");
const internals = @import("zply_internals");
const Property = internals.property.Property;
const Element = internals.element.Element;
const Header = internals.header.Header;
const ElementLayout = internals.layout.ElementLayout;
const chunks = internals.binary_chunk_builder;
const preflight = internals.binary_preflight;
const Pool = internals.batch_storage.Pool;

fn compile(properties: []const Property, count: u64) ![]ElementLayout {
    const elements = [_]Element{.{ .name = "record", .count = count, .properties = properties }};
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
const little = [_]u8{
    2, 10, 0, 0, 0, 11, 0, 0, 0, 0, 0, 128, 63, 3, 0, 7, 8, 9,
    0, 0, 0, 0, 64, 1, 0, 5,
    1, 12, 0, 0, 0, 0, 0, 64, 64, 0, 0,
};
const big = [_]u8{
    2, 0, 0, 0, 10, 0, 0, 0, 11, 63, 128, 0, 0, 0, 3, 7, 8, 9,
    0, 64, 0, 0, 0, 0, 1, 5,
    1, 0, 0, 0, 12, 64, 64, 0, 0, 0, 0,
};

const limits: internals.binary_boundary.Limits = .{
    .max_record_bytes = 4096,
    .max_list_items_per_record = 255,
};

test "Phase 10 binary output preflight and typed decoding preserve mixed lists in both endian formats" {
    const layouts = try compile(&props, 3);
    defer freeLayouts(layouts);
    inline for (.{ .little, .big }) |endian| {
        const data: []const u8 = if (endian == .little) &little else &big;
        var source: std.Io.Reader = .fixed(data);
        var builder: chunks.Builder = .{};
        defer builder.deinit(std.testing.allocator);
        const pool = try Pool.create(std.testing.allocator);
        defer pool.destroy();
        var next_record: u64 = 0;
        while (next_record < 3) {
            const chunk = (try builder.fill(std.testing.allocator, &source, &layouts[0], endian, limits, 24, next_record, 3 - next_record)).?;
            const planned = try preflight.plan(chunk, &layouts[0]);
            try std.testing.expectEqual(chunk.record_count, planned.record_count);
            try std.testing.expectEqual(chunk.bytes.len, planned.raw_bytes);
            const id = try pool.acquireBinaryVariableSized(&layouts[0], &props, chunk.record_count, chunk.list_item_totals);
            try Pool.decodePreparedBinaryVariable(pool.target(id), &layouts[0], endian, chunk.bytes, chunk.offsets, chunk.list_item_totals, null);
            var batch = pool.publish(id, .{
                .element_index = 0, .first_record = next_record,
                .record_count = chunk.record_count, .sequence = next_record,
            });
            {
                defer batch.release();
                const info = batch.info();
                try std.testing.expectEqual(next_record, info.first_record);
                const neighbors = try batch.listColumn(0);
                const confidences = try batch.typedColumn(f32, 1);
                const weights = try batch.listColumn(2);
                for (0..chunk.record_count) |r| {
                    const global = @as(usize, @intCast(next_record)) + r;
                    const expected_neighbors: []const i32 = switch (global) {
                        0 => &.{ 10, 11 }, 1 => &.{}, else => &.{12},
                    };
                    const expected_weights: []const u8 = switch (global) {
                        0 => &.{ 7, 8, 9 }, 1 => &.{5}, else => &.{},
                    };
                    try std.testing.expectEqualSlices(i32, expected_neighbors, neighbors.row(r).?.i32);
                    try std.testing.expectEqualSlices(u8, expected_weights, weights.row(r).?.u8);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(global + 1)), confidences[r]);
                }
                try std.testing.expectEqual(neighbors.values.len(), neighbors.offsets[chunk.record_count]);
                try std.testing.expectEqual(weights.values.len(), weights.offsets[chunk.record_count]);
            }
            next_record += @intCast(chunk.record_count);
            builder.consume();
        }
        try std.testing.expectEqual(@as(u64, 3), next_record);
        // The reader consumes exactly the three declared records.
    }
}

test "Phase 10 binary preflight rejects malformed boundaries and inconsistent scalar totals" {
    const layouts = try compile(&props, 3);
    defer freeLayouts(layouts);
    const chunk: chunks.Chunk = .{
        .element_index = 0, .first_record = 0, .record_count = 3,
        .first_body_byte_offset = 0, .bytes = &little,
        .offsets = &.{ 0, 18, 26, 37 },
        .list_item_totals = &.{ 3, 0, 4 },
    };
    const plan = try preflight.plan(chunk, &layouts[0]);
    // 3*i32 + 3*f32 + 4*u8 + 2*4*usize (three records, two list columns).
    try std.testing.expectEqual(@as(usize, 28) + 8 * @sizeOf(usize), plan.decoded_bytes);
    var invalid = chunk;
    invalid.offsets = &.{ 0, 18, 18, 37 };
    try std.testing.expectError(error.InvalidRecordBoundary, preflight.plan(invalid, &layouts[0]));
    try std.testing.expectError(error.InvalidLayout, preflight.decodedBytes(&layouts[0], 3, &.{ 3, 1, 4 }));
    try std.testing.expectError(error.SizeOverflow, preflight.decodedBytes(&layouts[0], 3, &.{ std.math.maxInt(usize), 0, 4 }));
}

test "Phase 10 binary output decoder rejects insufficient capacity and cooperative cancellation" {
    const layouts = try compile(&props, 3);
    defer freeLayouts(layouts);
    const pool = try Pool.create(std.testing.allocator);
    defer pool.destroy();
    const id = try pool.acquireBinaryVariableSized(&layouts[0], &props, 3, &.{ 3, 0, 4 });
    defer pool.cancel(id);
    const boundaries = [_]usize{ 0, 18, 26, 37 };
    try std.testing.expectError(error.InvalidOutputCapacity, Pool.decodePreparedBinaryVariable(
        pool.target(id), &layouts[0], .little, &little, &boundaries, &.{ 2, 0, 4 }, null,
    ));
    const cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, Pool.decodePreparedBinaryVariable(
        pool.target(id), &layouts[0], .little, &little, &boundaries, &.{ 3, 0, 4 }, &cancelled,
    ));
}

test "Phase 10 binary list item decoder preserves all eight scalar types and IEEE-754 bits" {
    const all = [_]Property{
        Property.list("i8", .u8, .i8), Property.list("u8", .u8, .u8),
        Property.list("i16", .u8, .i16), Property.list("u16", .u8, .u16),
        Property.list("i32", .u8, .i32), Property.list("u32", .u8, .u32),
        Property.list("f32", .u8, .f32), Property.list("f64", .u8, .f64),
    };
    const record = [_]u8{
        1, 0x80, 1, 0xff, 1, 0xff, 0x7f, 1, 0x34, 0x12,
        1, 0xfe, 0xff, 0xff, 0xff, 1, 0x78, 0x56, 0x34, 0x12,
        1, 0, 0, 0, 0x80,
        1, 1, 0, 0, 0, 0, 0, 0xf8, 0x7f,
    };
    const layouts = try compile(&all, 1);
    defer freeLayouts(layouts);
    const pool = try Pool.create(std.testing.allocator);
    defer pool.destroy();
    const totals = [_]usize{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const id = try pool.acquireBinaryVariableSized(&layouts[0], &all, 1, &totals);
    const boundaries = [_]usize{ 0, record.len };
    try Pool.decodePreparedBinaryVariable(pool.target(id), &layouts[0], .little, &record, &boundaries, &totals, null);
    var batch = pool.publish(id, .{ .element_index = 0, .first_record = 0, .record_count = 1, .sequence = 0 });
    defer batch.release();
    try std.testing.expectEqual(@as(i8, -128), (try batch.listColumn(0)).values.i8[0]);
    try std.testing.expectEqual(@as(u8, 255), (try batch.listColumn(1)).values.u8[0]);
    try std.testing.expectEqual(@as(i16, 32767), (try batch.listColumn(2)).values.i16[0]);
    try std.testing.expectEqual(@as(u16, 0x1234), (try batch.listColumn(3)).values.u16[0]);
    try std.testing.expectEqual(@as(i32, -2), (try batch.listColumn(4)).values.i32[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), (try batch.listColumn(5)).values.u32[0]);
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast((try batch.listColumn(6)).values.f32[0])));
    try std.testing.expectEqual(@as(u64, 0x7ff8000000000001), @as(u64, @bitCast((try batch.listColumn(7)).values.f64[0])));
}
