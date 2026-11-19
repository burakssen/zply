//! Phase 11 M9: independently generated PLY 1.0 reference records and schemas
//! are verified through the real streaming Parser, not through production
//! serializers or boundary-scanning helpers.
const std = @import("std");
const internal = @import("zply_internals");
const Parser = internal.parser.Parser;
const generator = @import("document_generator.zig");
const Document = generator.Document;
const Scalar = generator.Scalar;
const Encoding = generator.Encoding;

fn rawBits(value: anytype) u64 {
    const T = @TypeOf(value);
    // Zig 0.17.1 no longer exposes std.meta.Int. All PLY scalar values
    // have fixed bit widths, so select the corresponding unsigned type.
    const U = switch (@bitSizeOf(T)) {
        8 => u8,
        16 => u16,
        32 => u32,
        64 => u64,
        else => @compileError("unsupported PLY scalar bit width"),
    };
    return @as(u64, @as(U, @bitCast(value)));
}

fn checkValues(expected_type: Scalar, actual: anytype, bits: []const u64) !void {
    switch (actual) {
        inline else => |values, tag| {
            try std.testing.expectEqualStrings(@tagName(expected_type), @tagName(tag));
            try std.testing.expectEqual(bits.len, values.len);
            for (values, bits) |value, expected| {
                try std.testing.expectEqual(expected, rawBits(value));
            }
        },
    }
}

fn assertBudget(parser: *const Parser) !void {
    const mem = parser.memoryStats();
    try std.testing.expect(mem.live_bytes <= mem.budget_bytes);
    try std.testing.expect(mem.reserved_bytes <= mem.budget_bytes - mem.live_bytes);
    try std.testing.expect(mem.peak_total_bytes <= mem.budget_bytes);
}

fn verify(doc: *const Document, chunk_size: usize) !void {
    var source: std.Io.Reader = .fixed(doc.source());
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &source, .{
        .chunk_size = chunk_size,
        .memory_budget = 2 * 1024 * 1024,
    });
    defer parser.deinit();

    const header = parser.header();
    try std.testing.expectEqualStrings(@tagName(doc.encoding), @tagName(header.encoding));
    try std.testing.expectEqual(doc.element_count, header.elements.len);
    for (doc.elements[0..doc.element_count], 0..) |reference_element, e| {
        const actual = header.elements[e];
        var expected_name: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&expected_name, "element_{d}", .{e});
        try std.testing.expectEqualStrings(name, actual.name);
        try std.testing.expectEqual(@as(u64, @intCast(reference_element.count)), actual.count);
        try std.testing.expectEqual(reference_element.property_count, actual.properties.len);
        for (reference_element.properties[0..reference_element.property_count], 0..) |property, p| {
            const actual_prop = actual.properties[p];
            var expected_property_name: [32]u8 = undefined;
            const prop_name = try std.fmt.bufPrint(&expected_property_name, "field_{d}", .{p});
            try std.testing.expectEqualStrings(prop_name, actual_prop.name);
            if (property.is_list) {
                const list = actual_prop.listInfo() orelse return error.ExpectedListProperty;
                try std.testing.expectEqualStrings(@tagName(property.count_type), @tagName(list.count_type));
                try std.testing.expectEqualStrings(@tagName(property.ty), @tagName(list.item_type));
            } else {
                const ty = actual_prop.scalarType() orelse return error.ExpectedScalarProperty;
                try std.testing.expectEqualStrings(@tagName(property.ty), @tagName(ty));
            }
        }
    }

    var seen: [generator.max_elements]usize = @splat(0);
    var next_element: usize = 0;
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expect(info.record_count > 0);
        try std.testing.expect(info.element_index < doc.element_count);
        try std.testing.expect(info.element_index >= next_element);
        next_element = info.element_index;
        const e = info.element_index;
        const reference_element = doc.elements[e];
        try std.testing.expectEqual(@as(u64, @intCast(seen[e])), info.first_record);
        try std.testing.expect(seen[e] + info.record_count <= reference_element.count);
        try std.testing.expectEqual(reference_element.property_count, batch.columnCount());

        for (reference_element.properties[0..reference_element.property_count], 0..) |property, p| {
            if (property.is_list) {
                const list = try batch.listColumn(p);
                try std.testing.expectEqual(info.record_count + 1, list.offsets.len);
                try std.testing.expectEqual(@as(usize, 0), list.offsets[0]);
                var total: usize = 0;
                for (0..info.record_count) |r| {
                    const cell = doc.cells[e][seen[e] + r][p];
                    try std.testing.expectEqual(total, list.offsets[r]);
                    total += cell.len;
                    try std.testing.expectEqual(total, list.offsets[r + 1]);
                    const values = list.row(r) orelse return error.InvalidGeneratedList;
                    try checkValues(property.ty, values, cell.bits[0..cell.len]);
                }
                try std.testing.expectEqual(list.values.len(), total);
            } else {
                const col = batch.columnByPropertyIndex(p) orelse return error.MissingGeneratedColumn;
                try std.testing.expect(col.list == null);
                switch (col.values) {
                    inline else => |values, tag| {
                        try std.testing.expectEqualStrings(@tagName(property.ty), @tagName(tag));
                        try std.testing.expectEqual(info.record_count, values.len);
                        for (values, 0..) |value, r| {
                            const cell = doc.cells[e][seen[e] + r][p];
                            try std.testing.expectEqual(@as(usize, 1), cell.len);
                            try std.testing.expectEqual(cell.bits[0], rawBits(value));
                        }
                    },
                }
            }
        }
        seen[e] += info.record_count;
        try assertBudget(&parser);
    }
    for (doc.elements[0..doc.element_count], 0..) |element, e|
        try std.testing.expectEqual(element.count, seen[e]);
    try assertBudget(&parser);
    // The borrowed reader is only consumed through the last declared record.
    inline for ("TAIL") |byte| try std.testing.expectEqual(@as(u8, byte), try source.takeByte());
}

fn expectSameReference(a: *const Document, b: *const Document) !void {
    try std.testing.expectEqual(a.element_count, b.element_count);
    for (a.elements[0..a.element_count], 0..) |elem, e| {
        const other = b.elements[e];
        try std.testing.expectEqual(elem.count, other.count);
        try std.testing.expectEqual(elem.property_count, other.property_count);
        for (elem.properties[0..elem.property_count], 0..) |prop, p| {
            const other_prop = other.properties[p];
            try std.testing.expectEqual(prop.ty, other_prop.ty);
            try std.testing.expectEqual(prop.is_list, other_prop.is_list);
            if (prop.is_list) try std.testing.expectEqual(prop.count_type, other_prop.count_type);
            for (0..elem.count) |r| {
                const cell = a.cells[e][r][p];
                const other_cell = b.cells[e][r][p];
                try std.testing.expectEqual(cell.len, other_cell.len);
                try std.testing.expectEqualSlices(u64, cell.bits[0..cell.len], other_cell.bits[0..other_cell.len]);
            }
        }
    }
}

test "M9 bounded generator covers all scalar types, interleaved lists, and empty elements" {
    const a = try Document.generate(0, .ascii);
    try std.testing.expectEqual(@as(usize, 8), a.elements[0].property_count);
    const b = try Document.generate(1, .ascii);
    try std.testing.expect(b.elements[0].properties[1].is_list);
    try std.testing.expect(b.elements[0].properties[3].is_list);
    const c = try Document.generate(2, .ascii);
    try std.testing.expectEqual(@as(usize, 0), c.elements[0].count);
    try std.testing.expectEqual(@as(usize, 0), c.elements[1].property_count);
    const d = try Document.generate(3, .ascii);
    try std.testing.expectEqual(Scalar.i8, d.elements[0].properties[0].count_type);
    try std.testing.expectEqual(Scalar.u32, d.elements[0].properties[1].count_type);
    try std.testing.expectEqual(Scalar.i32, d.elements[0].properties[3].count_type);
}

test "M9 independent reference roundtrips all three encodings and small chunks" {
    inline for (.{ Encoding.ascii, Encoding.binary_little_endian, Encoding.binary_big_endian }) |enc| {
        for (0..36) |n| {
            const seed: u64 = @intCast(n);
            const doc = try Document.generate(seed, enc);
            try verify(&doc, 64);
            try verify(&doc, 512);
        }
    }
}

test "M9 same seed generates identical logical records across encodings" {
    for (0..36) |n| {
        const seed: u64 = @intCast(n);
        const ascii = try Document.generate(seed, .ascii);
        const le = try Document.generate(seed, .binary_little_endian);
        const be = try Document.generate(seed, .binary_big_endian);
        try expectSameReference(&ascii, &le);
        try expectSameReference(&ascii, &be);
        const again = try Document.generate(seed, .ascii);
        try std.testing.expectEqualSlices(u8, ascii.source(), again.source());
    }
}

fn fuzzGenerated(_: void, smith: *std.testing.Smith) !void {
    const seed = smith.value(u64);
    const enc: Encoding = @enumFromInt(smith.valueRangeAtMost(u8, 0, 2));
    const size: usize = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => 64, 1 => 128, else => 512,
    };
    const doc = try Document.generate(seed, enc);
    try verify(&doc, size);
}

test "M9 fuzz independently generated multi-element PLY schemas" {
    try std.testing.fuzz({}, fuzzGenerated, .{
        .corpus = &.{ "", "\x00", "\x01", "\x02", "\x03", "\x04", "\x05", "\xff\xff\xff\xff" },
    });
}
