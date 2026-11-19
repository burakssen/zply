//! Phase 11 M10: independent byte-level differential decoder and targeted
//! malformed-input mutations. Uses ONLY zply_internals to avoid assigning
//! shared source files to both zply and zply_internals modules in Zig 0.17.1.
const std = @import("std");
const internals = @import("zply_internals");
const Parser = internals.parser.Parser;
const generator = @import("document_generator.zig");
const reference = @import("reference_decoder.zig");
const Document = generator.Document;
const Encoding = generator.Encoding;

fn bitsOf(value: anytype) u64 {
    const T = @TypeOf(value);
    const U = switch (@bitSizeOf(T)) {
        8 => u8,
        16 => u16,
        32 => u32,
        64 => u64,
        else => @compileError("unsupported PLY scalar width"),
    };
    return @as(u64, @as(U, @bitCast(value)));
}

fn compareTyped(ty: reference.Scalar, actual: anytype, expected: []const u64) !void {
    switch (actual) {
        inline else => |values, tag| {
            try std.testing.expectEqualStrings(@tagName(ty), @tagName(tag));
            try std.testing.expectEqual(expected.len, values.len);
            for (values, expected) |value, bit_pattern|
                try std.testing.expectEqual(bit_pattern, bitsOf(value));
        },
    }
}

fn compareAgainstGenerator(doc: *const Document, oracle: *const reference.Result) !void {
    try std.testing.expectEqualStrings(@tagName(doc.encoding), @tagName(oracle.encoding));
    try std.testing.expectEqual(doc.element_count, oracle.element_count);
    for (doc.elements[0..doc.element_count], 0..) |element, e| {
        const decoded = oracle.elements[e];
        try std.testing.expectEqual(element.count, decoded.count);
        try std.testing.expectEqual(element.property_count, decoded.property_count);
        var expected_element_name: [32]u8 = undefined;
        const element_name = try std.fmt.bufPrint(&expected_element_name, "element_{d}", .{e});
        try std.testing.expectEqualStrings(element_name, decoded.name);
        for (element.properties[0..element.property_count], 0..) |property, p| {
            const other = decoded.properties[p];
            var expected_property_name: [32]u8 = undefined;
            const prop_name = try std.fmt.bufPrint(&expected_property_name, "field_{d}", .{p});
            try std.testing.expectEqualStrings(prop_name, other.name);
            try std.testing.expectEqualStrings(@tagName(property.ty), @tagName(other.ty));
            try std.testing.expectEqual(property.is_list, other.count_type != null);
            if (other.count_type) |ct| {
                try std.testing.expectEqualStrings(@tagName(property.count_type), @tagName(ct));
            }
            for (0..element.count) |r| {
                const a = doc.cells[e][r][p];
                const b = oracle.cells[e][r][p];
                try std.testing.expectEqual(a.len, b.len);
                try std.testing.expectEqualSlices(u64, a.bits[0..a.len], b.bits[0..b.len]);
            }
        }
    }
    try std.testing.expectEqual(doc.len - 4, oracle.body_end); // M9's trailing "TAIL".
}

fn compareProduction(input: []const u8, oracle: *const reference.Result, chunk_size: usize) !void {
    var reader: std.Io.Reader = .fixed(input);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = chunk_size,
        .memory_budget = 2 * 1024 * 1024,
        .limits = .{ .max_list_items_per_record = reference.max_items },
    });
    defer parser.deinit();

    const header = parser.header();
    try std.testing.expectEqualStrings(@tagName(oracle.encoding), @tagName(header.encoding));
    try std.testing.expectEqual(oracle.element_count, header.elements.len);
    for (oracle.elements[0..oracle.element_count], 0..) |element, e| {
        const actual = header.elements[e];
        try std.testing.expectEqualStrings(element.name, actual.name);
        try std.testing.expectEqual(@as(u64, @intCast(element.count)), actual.count);
        try std.testing.expectEqual(element.property_count, actual.properties.len);
        for (element.properties[0..element.property_count], 0..) |prop, p| {
            try std.testing.expectEqualStrings(prop.name, actual.properties[p].name);
            if (prop.count_type) |ct| {
                const info = actual.properties[p].listInfo() orelse return error.MissingDifferentialList;
                try std.testing.expectEqualStrings(@tagName(ct), @tagName(info.count_type));
                try std.testing.expectEqualStrings(@tagName(prop.ty), @tagName(info.item_type));
            } else {
                const ty = actual.properties[p].scalarType() orelse return error.MissingDifferentialScalar;
                try std.testing.expectEqualStrings(@tagName(prop.ty), @tagName(ty));
            }
        }
    }

    var seen: [reference.max_elements]usize = @splat(0);
    var last_element: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expect(info.record_count != 0);
        try std.testing.expect(info.element_index >= last_element);
        try std.testing.expect(info.element_index < oracle.element_count);
        const e = info.element_index;
        last_element = e;
        const element = oracle.elements[e];
        try std.testing.expectEqual(@as(u64, @intCast(seen[e])), info.first_record);
        try std.testing.expect(seen[e] + info.record_count <= element.count);
        try std.testing.expectEqual(element.property_count, batch.columnCount());
        for (element.properties[0..element.property_count], 0..) |prop, p| {
            if (prop.count_type != null) {
                const list = try batch.listColumn(p);
                try std.testing.expectEqual(info.record_count + 1, list.offsets.len);
                try std.testing.expectEqual(@as(usize, 0), list.offsets[0]);
                var total: usize = 0;
                for (0..info.record_count) |r| {
                    const cell = oracle.cells[e][seen[e] + r][p];
                    try std.testing.expectEqual(total, list.offsets[r]);
                    total += cell.len;
                    try std.testing.expectEqual(total, list.offsets[r + 1]);
                    try compareTyped(prop.ty, list.row(r) orelse return error.InvalidDifferentialList, cell.bits[0..cell.len]);
                }
                try std.testing.expectEqual(total, list.values.len());
            } else {
                const col = batch.columnByPropertyIndex(p) orelse return error.MissingDifferentialColumn;
                try std.testing.expect(col.list == null);
                switch (col.values) {
                    inline else => |values, tag| {
                        try std.testing.expectEqualStrings(@tagName(prop.ty), @tagName(tag));
                        try std.testing.expectEqual(info.record_count, values.len);
                        for (values, 0..) |scalar, r| {
                            const cell = oracle.cells[e][seen[e] + r][p];
                            try std.testing.expectEqual(@as(usize, 1), cell.len);
                            try std.testing.expectEqual(cell.bits[0], bitsOf(scalar));
                        }
                    },
                }
            }
        }
        seen[e] += info.record_count;
        const stats = parser.memoryStats();
        try std.testing.expect(stats.live_bytes <= stats.budget_bytes);
        try std.testing.expect(stats.reserved_bytes <= stats.budget_bytes - stats.live_bytes);
        try std.testing.expect(stats.peak_total_bytes <= stats.budget_bytes);
    }
    for (oracle.elements[0..oracle.element_count], 0..) |element, e|
        try std.testing.expectEqual(element.count, seen[e]);
    if (oracle.body_end < input.len)
        try std.testing.expectEqual(input[oracle.body_end], try reader.takeByte());
}

fn expectRejected(input: []const u8) !void {
    var reader: std.Io.Reader = .fixed(input);
    var init_diagnostic: internals.errors.Diagnostic = .{ .category = .header };
    var parser = Parser.initDetailed(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 64,
        .memory_budget = 2 * 1024 * 1024,
        .limits = .{ .max_list_items_per_record = reference.max_items },
    }, &init_diagnostic) catch |err| {
        if (init_diagnostic.code) |code| try std.testing.expectEqual(@as(anyerror, err), code);
        return;
    };
    defer parser.deinit();
    while (true) {
        const maybe = parser.next() catch |err| {
            const diagnostic = parser.lastDiagnostic() orelse return error.MissingDifferentialDiagnostic;
            try std.testing.expectEqual(@as(anyerror, err), diagnostic.code.?);
            return;
        };
        var batch = maybe orelse break;
        batch.release();
    }
    return error.MutatedPlyUnexpectedlyAccepted;
}

test "M10 independent byte decoder agrees with generated records and production parser" {
    inline for (.{ Encoding.ascii, Encoding.binary_little_endian, Encoding.binary_big_endian }) |enc| {
        for (0..32) |i| {
            const doc = try Document.generate(@intCast(i), enc);
            const oracle = try reference.decode(doc.source());
            try compareAgainstGenerator(&doc, &oracle);
            try compareProduction(doc.source(), &oracle, 64);
            try compareProduction(doc.source(), &oracle, 256);
        }
    }
}

test "M10 header mutations are rejected before body publication" {
    const invalid = [_][]const u8{
        "notply\nformat ascii 1.0\nelement a 0\nend_header\n",
        "ply\nformat ascii 1.0\nformat ascii 1.0\nelement a 0\nend_header\n",
        "ply\nformat ascii 1.0\nelement a 1\nproperty imaginary value\nend_header\n0\n",
        "ply\nformat ascii 1.0\nelement a 1\nproperty list float int indices\nend_header\n0\n",
        "ply\nformat ascii 1.0\nelement a -1\nproperty uchar value\nend_header\n",
        "ply\nformat binary_little_endian 2.0\nelement a 0\nend_header\n",
    };
    for (invalid) |input| {
        if (reference.decode(input)) |_| {
            return error.MalformedHeaderAcceptedByReference;
        } else |_| {}
        try expectRejected(input);
    }
}

test "M10 targeted record mutations reject ASCII and both binary endian forms" {
    inline for (.{ Encoding.ascii, Encoding.binary_little_endian, Encoding.binary_big_endian }) |enc| {
        // Family 1 begins with f32 followed by a u8 list count.
        var doc = try Document.generate(1, enc);
        if (enc == .ascii) {
            doc.bytes[doc.body_start] = '@'; // Invalid first float token.
        } else {
            doc.bytes[doc.body_start + 4] = 255; // Count exceeds configured list limit.
        }
        try expectRejected(doc.source());

        var truncated = try Document.generate(1, enc);
        truncated.len = truncated.body_start + 2; // First scalar / first line is incomplete.
        try expectRejected(truncated.source());

        if (enc != .ascii) {
            // First list has an u8 prefix and i32 items. Force two items,
            // then cut the payload halfway through the first item.
            var short_list = try Document.generate(1, enc);
            short_list.bytes[short_list.body_start + 4] = 2;
            short_list.len = short_list.body_start + 4 + 1 + 2;
            try expectRejected(short_list.source());
        }

        // Family 3 begins with an i8 list count, including its sign.
        var signed = try Document.generate(3, enc);
        if (enc == .ascii) {
            signed.bytes[signed.body_start] = '-';
        } else {
            signed.bytes[signed.body_start] = 0xff;
        }
        try expectRejected(signed.source());
    }
}

fn fuzzDifferential(_: void, smith: *std.testing.Smith) !void {
    const seed = smith.value(u64);
    const enc: Encoding = @fromBackingInt(@intCast(smith.valueRangeAtMost(u8, 0, 2)));
    var doc = try Document.generate(seed, enc);
    const body_size = doc.len - doc.body_start - 4; // Excludes M9's TAIL.
    const mutation = smith.valueRangeAtMost(u8, 0, 5);
    switch (mutation) {
        0 => {}, // Unmodified valid control.
        1 => {
            doc.bytes[0] = '!';
            try expectRejected(doc.source());
            return;
        },
        2 => {
            if (body_size != 0) {
                const cut: usize = smith.valueRangeAtMost(u16, 0, @intCast(body_size - 1));
                doc.len = doc.body_start + cut;
            }
        },
        3 => {
            if (body_size != 0) {
                const offset: usize = smith.valueRangeAtMost(u16, 0, @intCast(body_size - 1));
                doc.bytes[doc.body_start + offset] = smith.value(u8);
            }
        },
        4 => { // Body-preserving, change the bytes after declared records.
            doc.bytes[doc.len - 1] = smith.value(u8);
        },
        else => { // Force an oversized prefix on list-heavy schema family 3.
            doc = try Document.generate(seed -% (seed % 6) +% 3, enc);
            if (enc == .ascii) {
                doc.bytes[doc.body_start] = '9';
            } else {
                doc.bytes[doc.body_start] = 0x7f;
            }
            try expectRejected(doc.source());
            return;
        },
    }
    const oracle = reference.decode(doc.source()) catch {
        try expectRejected(doc.source());
        return;
    };
    try compareProduction(doc.source(), &oracle, 64);
}

test "M10 fuzz differential byte mutations of generated PLY documents" {
    try std.testing.fuzz({}, fuzzDifferential, .{
        .corpus = &.{ "", "\x00", "\x01\x02", "\x03\xff", "\xff\xff\xff\xff" },
    });
}
