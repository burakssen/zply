//! Deterministic property-based binary list boundary validation.
//! This is reproducible fuzz-style coverage; it is not a replacement for a
//! coverage-guided fuzzer or end-to-end differential testing with other tools.
const std = @import("std");
const internals = @import("zply_internals");
const scan = internals.binary_boundary;
const Property = internals.property.Property;
const Element = internals.element.Element;
const Header = internals.header.Header;
const Layout = internals.layout.ElementLayout;

const properties = [_]Property{
    Property.scalar("time", .f32),
    Property.list("faces", .u16, .u32),
    Property.list("flags", .u8, .u8),
    Property.scalar("stamp", .f64),
};
const limits: scan.Limits = .{ .max_record_bytes = 512, .max_list_items_per_record = 64 };

fn compiled() ![]Layout {
    const elements = [_]Element{.{ .name = "custom", .count = 1, .properties = &properties }};
    const header: Header = .{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    return internals.layout.compileSchema(std.testing.allocator, &header);
}

fn cleanup(layouts: []Layout) void {
    for (layouts) |layout| std.testing.allocator.free(layout.properties);
    std.testing.allocator.free(layouts);
}

test "Phase 10 randomized valid mixed-list binary records match independent widths and totals" {
    const layouts = try compiled();
    defer cleanup(layouts);
    var prng = std.Random.DefaultPrng.init(0x106ab1e);
    const random = prng.random();
    var bytes: [512]u8 = undefined;
    inline for (.{ .little, .big }) |endian| {
        for (0..2000) |_| {
            const a = random.intRangeAtMost(usize, 0, 32);
            const b = random.intRangeAtMost(usize, 0, 32);
            const expected_size = 4 + 2 + 4 * a + 1 + b + 8;
            var offset: usize = 0;
            random.bytes(bytes[offset .. offset + 4]);
            offset += 4;
            std.mem.writeInt(u16, bytes[offset..][0..2], @intCast(a), endian);
            offset += 2;
            for (0..a) |_| {
                random.bytes(bytes[offset .. offset + 4]);
                offset += 4;
            }
            bytes[offset] = @intCast(b);
            offset += 1;
            random.bytes(bytes[offset .. offset + b]);
            offset += b;
            random.bytes(bytes[offset .. offset + 8]);
            offset += 8;
            try std.testing.expectEqual(expected_size, offset);
            var counts = [_]usize{ 0, 0, 0, 0 };
            const result = try scan.scanRecord(&layouts[0], endian, bytes[0..offset], limits, &counts);
            switch (result) {
                .incomplete => return error.UnexpectedIncomplete,
                .complete => |record| {
                    try std.testing.expectEqual(expected_size, record.byte_length);
                    try std.testing.expectEqual(a + b, record.total_list_items);
                    try std.testing.expectEqualSlices(usize, &.{ 0, a, b, 0 }, &counts);
                },
            }
            // Every truncated prefix must be classified as incomplete, with
            // a requirement strictly beyond that prefix, never as complete.
            const prefix = random.intRangeAtMost(usize, 0, offset - 1);
            switch (try scan.scanRecord(&layouts[0], endian, bytes[0..prefix], limits, null)) {
                .complete => return error.UnexpectedComplete,
                .incomplete => |part| {
                    try std.testing.expect(part.required_total > prefix);
                    try std.testing.expect(part.required_total <= offset);
                    try std.testing.expect(part.property_index < properties.len);
                },
            }
        }
    }
}

test "Phase 10 random untrusted byte prefixes never produce unchecked record offsets" {
    const layouts = try compiled();
    defer cleanup(layouts);
    var prng = std.Random.DefaultPrng.init(0x10f00d5);
    const random = prng.random();
    var bytes: [512]u8 = undefined;
    inline for (.{ .little, .big }) |endian| {
        for (0..5000) |_| {
            random.bytes(&bytes);
            const n = random.intRangeAtMost(usize, 0, bytes.len);
            const result = scan.scanRecord(&layouts[0], endian, bytes[0..n], limits, null) catch |err| {
                switch (err) {
                    error.NegativeListCount, error.CountOverflow, error.ListTooLarge,
                    error.RecordTooLarge, error.SizeOverflow => {},
                    error.InvalidLayout => return error.UnexpectedInvalidLayout,
                }
                continue;
            };
            switch (result) {
                .complete => |record| {
                    try std.testing.expect(record.byte_length >= layouts[0].minimum_record_size);
                    try std.testing.expect(record.byte_length <= n);
                    try std.testing.expect(record.byte_length <= limits.max_record_bytes);
                    try std.testing.expect(record.total_list_items <= limits.max_list_items_per_record * 2);
                },
                .incomplete => |part| {
                    try std.testing.expect(part.property_index < properties.len);
                    try std.testing.expect(part.required_total > n);
                    try std.testing.expect(part.required_total <= limits.max_record_bytes);
                },
            }
        }
    }
}
