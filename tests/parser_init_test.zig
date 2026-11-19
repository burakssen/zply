//! Integration tests for the functional `Parser.init` (Tasks 2.12–2.14):
//! the initialization sequence, reader independence, ownership/leak
//! behavior under allocation failure, body-byte preservation, property-based
//! header generation, and fuzz-style robustness.
//!
//! Uses the public `zply` module exclusively.

const std = @import("std");
const ply = @import("zply");

/// The canonical example from the phase spec.
const sample_bytes =
    "ply\n" ++
    "format binary_little_endian 1.0\n" ++
    "comment Generated point cloud\n" ++
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

test "the spec's final example works end to end" {
    var reader: std.Io.Reader = .fixed(sample_bytes);
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );
    defer parser.deinit();

    const header = parser.header();
    try std.testing.expectEqual(ply.Encoding.binary_little_endian, header.encoding);
    try std.testing.expectEqual(@as(u16, 1), header.version.major);
    try std.testing.expectEqual(@as(u16, 0), header.version.minor);

    try std.testing.expectEqual(@as(usize, 2), header.elements.len);
    const vertex = header.elements[0];
    try std.testing.expectEqualStrings("vertex", vertex.name);
    try std.testing.expectEqual(@as(u64, 1000000), vertex.count);
    try std.testing.expectEqual(@as(usize, 6), vertex.properties.len);
    try std.testing.expectEqualStrings("blue", vertex.properties[5].name);

    const face = header.elements[1];
    try std.testing.expectEqualStrings("face", face.name);
    try std.testing.expectEqual(@as(u64, 500000), face.count);

    try std.testing.expectEqual(@as(usize, 1), header.comments.len);
    try std.testing.expectEqualStrings("Generated point cloud", header.comments[0]);
    try std.testing.expectEqual(@as(usize, 0), header.obj_info.len);

    // Compiled layouts, accessible from the parser.
    const layouts = parser.layouts();
    try std.testing.expectEqual(@as(usize, 2), layouts.len);
    try std.testing.expectEqual(@as(?usize, 27), layouts[0].fixed_record_size);
    try std.testing.expectEqual(@as(?usize, null), layouts[1].fixed_record_size);

    // Reader is at the body; header() and layouts() do not read.
    const position_before = reader.seek;
    _ = parser.header();
    _ = parser.layouts();
    try std.testing.expectEqual(position_before, reader.seek);
}

test "body bytes are preserved after init (LF and CRLF)" {
    const lf =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "element vertex 1\n" ++
        "property uchar x\n" ++
        "end_header\n" ++
        "\x00\xFF\x10\x20";
    const crlf =
        "ply\r\n" ++
        "format binary_little_endian 1.0\r\n" ++
        "element vertex 1\r\n" ++
        "property uchar x\r\n" ++
        "end_header\r\n" ++
        "\x00\xFF\x10\x20";

    for ([_][]const u8{ lf, crlf }) |bytes| {
        var reader: std.Io.Reader = .fixed(bytes);
        var parser = try ply.Parser.init(
            std.testing.allocator,
            std.testing.io,
            &reader,
            .{},
        );
        defer parser.deinit();

        // The next logical read returns the first body byte: 0x00.
        try std.testing.expectEqual(@as(u8, 0x00), try reader.takeByte());
        try std.testing.expectEqual(@as(u8, 0xFF), try reader.takeByte());
        try std.testing.expectEqual(@as(u8, 0x10), try reader.takeByte());
        try std.testing.expectEqual(@as(u8, 0x20), try reader.takeByte());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }
}

test "fragmented readers of every shape produce identical metadata" {
    const bytes = sample_bytes;

    // Shape 1: fixed in-memory reader.
    var reader_fixed: std.Io.Reader = .fixed(bytes);
    var parser_fixed = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader_fixed,
        .{},
    );
    defer parser_fixed.deinit();

    // Shape 2: one-byte-at-a-time delivery (buffer smaller than any line).
    var underlying: std.Io.Reader = .fixed(bytes);
    var small_buf: [1]u8 = undefined;
    var limited: std.Io.Reader.Limited = .init(&underlying, .unlimited, &small_buf);
    var parser_limited = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &limited.interface,
        .{},
    );
    defer parser_limited.deinit();

    // Shape 3: irregular small fragments (buffer of 3).
    var underlying3: std.Io.Reader = .fixed(bytes);
    var buf3: [3]u8 = undefined;
    var limited3: std.Io.Reader.Limited = .init(&underlying3, .unlimited, &buf3);
    var parser_limited3 = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &limited3.interface,
        .{},
    );
    defer parser_limited3.deinit();

    const a = parser_fixed.header();
    const b = parser_limited.header();
    const c = parser_limited3.header();

    try std.testing.expectEqual(a.encoding, b.encoding);
    try std.testing.expectEqual(a.encoding, c.encoding);
    try std.testing.expectEqual(a.body_offset, b.body_offset);
    try std.testing.expectEqual(a.body_offset, c.body_offset);

    for (a.elements, b.elements, c.elements) |ea, eb, ec| {
        try std.testing.expectEqualStrings(ea.name, eb.name);
        try std.testing.expectEqualStrings(ea.name, ec.name);
        try std.testing.expectEqual(ea.count, eb.count);
        try std.testing.expectEqual(ea.count, ec.count);
        try std.testing.expectEqual(ea.properties.len, eb.properties.len);
        for (ea.properties, eb.properties, ec.properties) |pa, pb, pc| {
            try std.testing.expectEqualStrings(pa.name, pb.name);
            try std.testing.expectEqualStrings(pa.name, pc.name);
            try std.testing.expectEqual(
                @as([]const u8, @tagName(pa.kind)),
                @tagName(pb.kind),
            );
            try std.testing.expectEqual(
                @as([]const u8, @tagName(pa.kind)),
                @tagName(pc.kind),
            );
        }
    }
}

test "mid-stream reader: body_offset is relative to the start position" {
    const document = "PREFIX_JUNK" ++ sample_bytes ++ "TRAILING_BODY";
    var reader: std.Io.Reader = .fixed(document);
    reader.seek = 11;

    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );
    defer parser.deinit();

    try std.testing.expectEqual(@as(u64, sample_bytes.len), parser.header().body_offset);
    try std.testing.expectEqual(@as(u8, 'T'), try reader.takeByte());
}

test "deinit releases everything and leaves the reader usable" {
    var reader: std.Io.Reader = .fixed(sample_bytes ++ "BODY");
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );

    // Touch metadata so a use-after-free would be visible.
    const header = parser.header();
    try std.testing.expectEqualStrings("vertex", header.elements[0].name);

    parser.deinit();

    // The parser never reads during destruction (invariant 6)...
    try std.testing.expectEqual(@as(u64, sample_bytes.len), reader.seek);
    // ...and the caller's reader remains usable afterwards.
    try std.testing.expectEqual(@as(u8, 'B'), try reader.takeByte());
}

test "successful init then deinit is leak-free across many shapes" {
    const shapes = [_][]const u8{
        "ply\nformat ascii 1.0\nend_header\n",
        "ply\r\nformat binary_big_endian 1.0\r\nend_header\r\n",
        "ply\nformat ascii 1.0\nelement a 0\nend_header\n",
        sample_bytes,
        "ply\nformat ascii 1.0\ncomment c\nobj_info o\nelement a 0\nelement b 0\nend_header\n",
    };

    for (shapes) |bytes| {
        var reader: std.Io.Reader = .fixed(bytes);
        var parser = try ply.Parser.init(
            std.testing.allocator,
            std.testing.io,
            &reader,
            .{},
        );
        parser.deinit();
    }
}

test "allocation failure during init leaves no leaks" {
    // How many allocations does one init need? Discover by walking the
    // fail index until success, expecting OutOfMemory before that.
    var fail_index: usize = 0;
    var succeeded = false;
    while (fail_index < 1000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var reader: std.Io.Reader = .fixed(sample_bytes);
        if (ply.Parser.init(failing.allocator(), std.testing.io, &reader, .{})) |parser| {
            var p = parser;
            p.deinit();
            succeeded = true;
            break;
        } else |err| switch (err) {
            error.OutOfMemory => continue,
            // A header error at an OOM-induced truncation would be a
            // contract violation: allocation failure must surface as
            // error.OutOfMemory.
            else => {
                std.debug.print("fail_index={d}: unexpected error {s}\n", .{ fail_index, @errorName(err) });
                return err;
            },
        }
    }
    try std.testing.expect(succeeded);
    // The success must not have happened on the very first index (i.e. the
    // failing allocator actually exercised at least one OOM path).
    try std.testing.expect(fail_index > 0);
}

test "allocation failure during malformed-header init leaves no leaks" {
    const malformed =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 3\n" ++
        "property float x\n" ++
        "property bogus_type z\n" ++
        "end_header\n";
    var fail_index: usize = 0;
    var saw_expected = false;
    while (fail_index < 1000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var reader: std.Io.Reader = .fixed(malformed);
        if (ply.Parser.init(failing.allocator(), std.testing.io, &reader, .{})) |parser_value| {
            var p = parser_value;
            p.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => continue,
            error.InvalidScalarType => {
                saw_expected = true;
                break;
            },
            else => return err,
        }
    }
    try std.testing.expect(saw_expected);
}

test "next() reports a missing declared binary body" {
    var reader: std.Io.Reader = .fixed(sample_bytes);
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );
    defer parser.deinit();

    try std.testing.expectEqual(ply.Parser.State.ready, parser.state);
    try std.testing.expectError(error.TruncatedBody, parser.next());
}

// ---------------------------------------------------------------------------
// Property-based tests: randomized valid headers
// ---------------------------------------------------------------------------

const ScalarName = struct { name: []const u8, scalar: ply.ScalarType };

const scalar_table = [_]ScalarName{
    .{ .name = "char", .scalar = .i8 },
    .{ .name = "uchar", .scalar = .u8 },
    .{ .name = "short", .scalar = .i16 },
    .{ .name = "ushort", .scalar = .u16 },
    .{ .name = "int", .scalar = .i32 },
    .{ .name = "uint", .scalar = .u32 },
    .{ .name = "float", .scalar = .f32 },
    .{ .name = "double", .scalar = .f64 },
};

const count_names = [_][]const u8{ "char", "uchar", "short", "ushort", "int", "uint" };

const property_names = [_][]const u8{
    "x",           "y",           "z",    "nx",        "normal_x",  "confidence",
    "red",         "green",       "blue", "alpha",     "timestamp", "vertex_indices",
    "my_custom_1", "wedge_count", "knn",  "intensity", "temp",      "a",
};

test "randomized valid headers round-trip exactly" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 32) : (trial += 1) {
        var header_text: std.ArrayList(u8) = .empty;
        defer header_text.deinit(allocator);
        const eol: []const u8 = if (trial % 2 == 0) "\n" else "\r\n";

        var expected_elements: std.ArrayList(ExpectedElement) = .empty;
        defer expected_elements.deinit(allocator);

        try header_text.appendSlice(allocator, "ply\n");
        try header_text.appendSlice(allocator, "format ascii 1.0\n");

        // Optional comment and obj_info lines.
        const comment_count = rand.uintLessThan(usize, 3);
        for (0..comment_count) |i| {
            var num_buf: [8]u8 = undefined;
            try header_text.appendSlice(allocator, "comment generated comment ");
            try header_text.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{i}));
            try header_text.appendSlice(allocator, eol);
        }
        if (rand.boolean()) {
            try header_text.appendSlice(allocator, "obj_info random object info");
            try header_text.appendSlice(allocator, eol);
        }

        const element_count = 1 + rand.uintLessThan(usize, 4);
        for (0..element_count) |ei| {
            var name_buf: [16]u8 = undefined;
            var num_buf: [32]u8 = undefined;
            const element_name = try std.fmt.bufPrint(&name_buf, "elem{d}", .{ei});
            const record_count = rand.uintLessThan(u64, 100000);

            try header_text.appendSlice(allocator, "element ");
            try header_text.appendSlice(allocator, element_name);
            try header_text.appendSlice(allocator, " ");
            try header_text.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{record_count}));
            try header_text.appendSlice(allocator, eol);

            var expected_properties: [7]ExpectedProperty = undefined;
            var expected_property_count: usize = 0;

            const property_count = rand.uintLessThan(usize, 7);
            for (0..property_count) |pi| {
                var prop_name_buf: [24]u8 = undefined;
                const is_list = rand.boolean();
                // Suffix the index so names are unique within the element
                // (strict mode rejects duplicate property names).
                const property_name = try std.fmt.bufPrint(
                    &prop_name_buf,
                    "{s}_{d}",
                    .{ property_names[rand.uintLessThan(usize, property_names.len)], pi },
                );
                try header_text.appendSlice(allocator, "property ");
                if (is_list) {
                    const count_name = count_names[rand.uintLessThan(usize, count_names.len)];
                    const item = scalar_table[rand.uintLessThan(usize, scalar_table.len)];
                    try header_text.appendSlice(allocator, "list ");
                    try header_text.appendSlice(allocator, count_name);
                    try header_text.appendSlice(allocator, " ");
                    try header_text.appendSlice(allocator, item.name);
                    try header_text.appendSlice(allocator, " ");
                    try header_text.appendSlice(allocator, property_name);
                    expected_properties[pi] = .{
                        .kind = .list,
                        .scalar = item.scalar,
                    };
                } else {
                    const item = scalar_table[rand.uintLessThan(usize, scalar_table.len)];
                    try header_text.appendSlice(allocator, item.name);
                    try header_text.appendSlice(allocator, " ");
                    try header_text.appendSlice(allocator, property_name);
                    expected_properties[pi] = .{
                        .kind = .scalar,
                        .scalar = item.scalar,
                    };
                }
                try header_text.appendSlice(allocator, eol);
                expected_property_count = pi + 1;
            }

            try expected_elements.append(allocator, .{
                .name_len = element_name.len,
                .name = name_buf,
                .count = record_count,
                .properties = expected_properties,
                .property_count = expected_property_count,
            });
        }

        try header_text.appendSlice(allocator, "end_header\n");
        // Sentinel body bytes.
        try header_text.appendSlice(allocator, "\xAB\xCD\x01");

        // Parse.
        var reader: std.Io.Reader = .fixed(header_text.items);
        var parser = try ply.Parser.init(allocator, std.testing.io, &reader, .{});
        defer parser.deinit();

        const header = parser.header();
        try std.testing.expectEqual(
            @as(u64, header_text.items.len - 3),
            header.body_offset,
        );
        try std.testing.expectEqual(expected_elements.items.len, header.elements.len);

        for (expected_elements.items, 0..) |*expected, i| {
            const element = header.elements[i];
            try std.testing.expectEqualStrings(expected.nameSlice(), element.name);
            try std.testing.expectEqual(expected.count, element.count);
            try std.testing.expectEqual(expected.property_count, element.properties.len);
            for (expected.properties[0..expected.property_count], 0..) |expected_property, pi| {
                const property = element.properties[pi];
                switch (expected_property.kind) {
                    .scalar => {
                        try std.testing.expect(property.isScalar());
                        try std.testing.expectEqual(
                            expected_property.scalar,
                            property.scalarType().?,
                        );
                    },
                    .list => {
                        try std.testing.expect(property.isList());
                        try std.testing.expectEqual(
                            expected_property.scalar,
                            property.listInfo().?.item_type,
                        );
                    },
                }
            }
        }

        // The next body byte is the sentinel.
        try std.testing.expectEqual(@as(u8, 0xAB), try reader.takeByte());
    }
}

const ExpectedProperty = struct {
    kind: enum { scalar, list },
    scalar: ply.ScalarType,
};

const ExpectedElement = struct {
    /// Inline copy of the generated element name (stack buffers of each
    /// generator iteration die immediately, so the expectation must own it).
    name: [16]u8,
    name_len: usize,
    count: u64,
    /// Inline property expectations; a fixed array avoids any pointer that
    /// could outlive per-element scratch storage.
    properties: [7]ExpectedProperty,
    property_count: usize,

    fn nameSlice(self: *const ExpectedElement) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ---------------------------------------------------------------------------
// Fuzz-style robustness: random bytes must never panic, hang, or leak
// ---------------------------------------------------------------------------

test "random byte sequences either parse or produce a controlled error" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xBADF00D);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 512) : (trial += 1) {
        var bytes: [64]u8 = undefined;
        const length = rand.uintLessThan(usize, bytes.len);
        for (bytes[0..length]) |*byte| {
            // Bias toward header-ish bytes so many sequences get past the
            // magic line and exercise deeper grammar states.
            byte.* = switch (rand.uintLessThan(u8, 4)) {
                0 => rand.int(u8),
                1 => "ply format element1.0 \n"[rand.uintLessThan(usize, 23)],
                2 => "\n"[0],
                else => "abcdefghijklmnopqrstuvwxyz_"[rand.uintLessThan(usize, 27)],
            };
        }

        var reader: std.Io.Reader = .fixed(bytes[0..length]);
        if (ply.Parser.init(allocator, std.testing.io, &reader, .{})) |parser_value| {
            var parser = parser_value;
            parser.deinit();
        } else |_| {
            // Any controlled error is acceptable.
        }
    }
}

test "hostile truncated headers terminate without panicking" {
    const base = "ply\nformat ascii 1.0\nelement vertex 999999999\nproperty list uchar int x\n";
    var length: usize = 0;
    while (length <= base.len) : (length += 1) {
        var reader: std.Io.Reader = .fixed(base[0..length]);
        if (ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{})) |parser_value| {
            var parser = parser_value;
            parser.deinit();
        } else |_| {}
    }
}
