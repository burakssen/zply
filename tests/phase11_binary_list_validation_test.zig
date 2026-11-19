//! Phase 11 M6: binary list structural and publication-boundary hardening.
//! Generated expected values are independent of the production decoder.
const std = @import("std");
const internal = @import("zply_internals");
const Property = internal.property.Property;
const Element = internal.element.Element;
const Header = internal.header.Header;
const Layout = internal.layout.ElementLayout;
const Pool = internal.batch_storage.Pool;
const scan = internal.binary_boundary;
const preflight = internal.binary_preflight;
const Chunk = internal.binary_chunk_builder.Chunk;

const props = [_]Property{
    Property.list("indices", .u8, .i32),
    Property.scalar("confidence", .f32),
    Property.list("flags", .u16, .u8),
};

// Records: ([10, 11], 1.0, [7, 8, 9]), ([], 2.0, [5]),
//          ([12], 3.0, []). No alignment bytes between properties.
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
const boundaries = [_]usize{ 0, 18, 26, 37 };
const totals = [_]usize{ 3, 0, 4 };
const limits: scan.Limits = .{ .max_record_bytes = 1024, .max_list_items_per_record = 128 };

fn layoutsFor(properties: []const Property) ![]Layout {
    const elements = [_]Element{.{ .name = "face", .count = 3, .properties = properties }};
    const header: Header = .{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    return internal.layout.compileSchema(std.testing.allocator, &header);
}

fn freeLayouts(layouts: []Layout) void {
    for (layouts) |layout| std.testing.allocator.free(layout.properties);
    std.testing.allocator.free(layouts);
}

test "M6 both endian mixed-list records have exact boundaries, totals and published offsets" {
    const layouts = try layoutsFor(&props);
    defer freeLayouts(layouts);

    inline for (.{ .little, .big }) |endian| {
        const bytes: []const u8 = if (endian == .little) &little else &big;
        var scanned_totals = [_]usize{ 0, 0, 0 };
        for (0..3) |record| {
            const start = boundaries[record];
            const end = boundaries[record + 1];
            var counts = [_]usize{ 0, 0, 0 };
            switch (try scan.scanRecord(&layouts[0], endian, bytes[start..end], limits, &counts)) {
                .incomplete => return error.UnexpectedTruncation,
                .complete => |result| try std.testing.expectEqual(end - start, result.byte_length),
            }
            for (&scanned_totals, counts) |*total, count| total.* += count;
        }
        try std.testing.expectEqualSlices(usize, &totals, &scanned_totals);

        const chunk: Chunk = .{
            .element_index = 0, .first_record = 0, .record_count = 3,
            .first_body_byte_offset = 0, .bytes = bytes,
            .offsets = &boundaries, .list_item_totals = &totals,
        };
        const plan = try preflight.plan(chunk, &layouts[0]);
        try std.testing.expectEqual(@as(usize, 37), plan.raw_bytes);
        // 3*i32 + 3*f32 + 4*u8 + two (3+1)-entry usize offset arrays.
        try std.testing.expectEqual(@as(usize, 28) + 8 * @sizeOf(usize), plan.decoded_bytes);

        const pool = try Pool.create(std.testing.allocator);
        defer pool.destroy();
        const id = try pool.acquireBinaryVariableSized(&layouts[0], &props, 3, &totals);
        try Pool.decodePreparedBinaryVariable(pool.target(id), &layouts[0], endian, bytes, &boundaries, &totals, null);
        var batch = pool.publish(id, .{ .element_index = 0, .first_record = 0, .record_count = 3, .sequence = 0 });
        defer batch.release();
        const indices = try batch.listColumn(0);
        const flags = try batch.listColumn(2);
        try std.testing.expectEqualSlices(usize, &.{ 0, 2, 2, 3 }, indices.offsets);
        try std.testing.expectEqualSlices(usize, &.{ 0, 3, 4, 4 }, flags.offsets);
        try std.testing.expectEqualSlices(i32, &.{ 10, 11 }, indices.row(0).?.i32);
        try std.testing.expectEqual(@as(usize, 0), indices.row(1).?.i32.len);
        try std.testing.expectEqualSlices(i32, &.{12}, indices.row(2).?.i32);
        try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, flags.row(0).?.u8);
        try std.testing.expectEqualSlices(u8, &.{5}, flags.row(1).?.u8);
        try std.testing.expectEqual(@as(usize, 0), flags.row(2).?.u8.len);
        try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0, 3.0 }, try batch.typedColumn(f32, 1));
    }
}

test "M6 invalid later list target does not mutate earlier list offset during preflight" {
    const layouts = try layoutsFor(&props);
    defer freeLayouts(layouts);
    const pool = try Pool.create(std.testing.allocator);
    defer pool.destroy();
    const id = try pool.acquireBinaryVariableSized(&layouts[0], &props, 3, &totals);
    defer pool.cancel(id);

    const target = pool.target(id);
    const first_offsets = target.list_offsets[0].?;
    const last_offsets = target.list_offsets[2].?;
    first_offsets[0] = 777;
    last_offsets[0] = 888;
    var invalid_entries = [_]?[]usize{ target.list_offsets[0], target.list_offsets[1], null };
    var invalid_target = target;
    invalid_target.list_offsets = &invalid_entries;
    try std.testing.expectError(error.InvalidOutputCapacity, Pool.decodePreparedBinaryVariable(
        invalid_target, &layouts[0], .little, &little, &boundaries, &totals, null,
    ));
    try std.testing.expectEqual(@as(usize, 777), first_offsets[0]);
    try std.testing.expectEqual(@as(usize, 888), last_offsets[0]);

    // Reusing the valid target after failure must initialize the offsets.
    try Pool.decodePreparedBinaryVariable(target, &layouts[0], .little, &little, &boundaries, &totals, null);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 2, 3 }, first_offsets);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 4, 4 }, last_offsets);
}

test "M6 preflight rejects overlapping, decreasing, and out-of-range record boundaries" {
    const layouts = try layoutsFor(&props);
    defer freeLayouts(layouts);
    const base: Chunk = .{
        .element_index = 0, .first_record = 0, .record_count = 3,
        .first_body_byte_offset = 0, .bytes = &little,
        .offsets = &boundaries, .list_item_totals = &totals,
    };
    const cases = [_][]const usize{
        &.{ 0, 18, 18, 37 }, // zero-width record
        &.{ 0, 26, 18, 37 }, // decreasing boundaries
        &.{ 0, 18, 40, 37 }, // out of range
        &.{ 1, 18, 26, 37 }, // missing initial zero
        &.{ 0, 18, 26, 36 }, // missing final byte
    };
    for (cases) |offsets| {
        var changed = base;
        changed.offsets = offsets;
        try std.testing.expectError(error.InvalidRecordBoundary, preflight.plan(changed, &layouts[0]));
    }
}

test "M6 signed list counts reject negative values and unsigned counts honor configured limits in both endian formats" {
    const signed_props = [_]Property{Property.list("values", .i16, .f64)};
    const unsigned_props = [_]Property{Property.list("values", .u32, .f64)};
    const signed_layouts = try layoutsFor(&signed_props);
    defer freeLayouts(signed_layouts);
    const unsigned_layouts = try layoutsFor(&unsigned_props);
    defer freeLayouts(unsigned_layouts);
    inline for (.{ .little, .big }) |endian| {
        var signed_bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &signed_bytes, -1, endian);
        try std.testing.expectError(error.NegativeListCount, scan.scanRecord(
            &signed_layouts[0], endian, &signed_bytes, limits, null,
        ));
        var unsigned_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &unsigned_bytes, 129, endian);
        try std.testing.expectError(error.ListTooLarge, scan.scanRecord(
            &unsigned_layouts[0], endian, &unsigned_bytes, limits, null,
        ));
        std.mem.writeInt(u32, &unsigned_bytes, 128, endian);
        try std.testing.expectError(error.RecordTooLarge, scan.scanRecord(
            &unsigned_layouts[0], endian, &unsigned_bytes, limits, null,
        ));
    }
}
