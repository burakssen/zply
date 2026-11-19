//! Adversarial decode tests (Tasks 3.10, 3.11, 3.14): malformed layouts
//! are rejected without memory corruption, truncated inputs fail
//! cleanly, and overflow arithmetic is checked.
//!
//! Uses the internals universe exclusively.

const std = @import("std");
const support = @import("decode_support.zig");

const decode = support.decode;
const types = support.types;
const layout_mod = internals_layout;
const ScalarValue = support.ScalarValue;

const internals_layout = @import("zply_internals").layout;

// ---------------------------------------------------------------------------
// Layout validation at the decoder boundary (Task 3.10)
// ---------------------------------------------------------------------------

/// Builds a hand-crafted `ElementLayout` from raw field values (the
/// decoder must not trust its callers).
fn handmadeLayout(
    record_size: ?usize,
    properties: []const layout_mod.PropertyLayout,
) layout_mod.ElementLayout {
    return .{
        .element_index = 0,
        .fixed_record_size = record_size,
        .minimum_record_size = record_size orelse 0,
        .body_start_offset = 0,
        .fixed_body_size = null,
        .properties = properties,
    };
}

test "a valid hand-crafted fixed layout is accepted" {
    const properties = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 4, .scalar_type = .f32 },
        .{ .property_index = 1, .fixed_offset = 4, .fixed_width = 1, .scalar_type = .u8 },
        .{ .property_index = 2, .fixed_offset = 5, .fixed_width = 2, .scalar_type = .i16 },
    };
    const element = handmadeLayout(7, &properties);
    const fixed = try decode.FixedLayout.init(&element, .little);
    try std.testing.expectEqual(@as(usize, 7), fixed.record_size);
    try std.testing.expectEqual(@as(usize, 3), fixed.propertyCount());
}

test "missing fixed_record_size is rejected as variable-length" {
    const properties = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = null, .scalar_type = null },
    };
    const element = handmadeLayout(null, &properties);
    try std.testing.expectError(
        error.VariableLengthElement,
        decode.FixedLayout.init(&element, .little),
    );
}

test "a list property inside a fixed layout is rejected" {
    // Record size present but one property has no fixed width.
    const properties = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 4, .scalar_type = .f32 },
        .{ .property_index = 1, .fixed_offset = 4, .fixed_width = null, .scalar_type = null },
    };
    const element = handmadeLayout(5, &properties);
    try std.testing.expectError(
        error.VariableLengthElement,
        decode.FixedLayout.init(&element, .little),
    );
}

test "a width that contradicts the declared scalar type is InvalidLayout" {
    // Declared u8 but fixed_width 4.
    const properties = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 4, .scalar_type = .u8 },
    };
    const element = handmadeLayout(4, &properties);
    try std.testing.expectError(
        error.InvalidLayout,
        decode.FixedLayout.init(&element, .little),
    );

    // Declared f64 but width 4.
    const properties2 = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 4, .scalar_type = .f64 },
    };
    const element2 = handmadeLayout(4, &properties2);
    try std.testing.expectError(
        error.InvalidLayout,
        decode.FixedLayout.init(&element2, .little),
    );
}

test "overlapping or gappy property ranges are InvalidLayout" {
    // Overlap: property 1 starts before property 0 ends.
    const overlapping = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 4, .scalar_type = .f32 },
        .{ .property_index = 1, .fixed_offset = 3, .fixed_width = 1, .scalar_type = .u8 },
    };
    const overlap_element = handmadeLayout(5, &overlapping);
    try std.testing.expectError(
        error.InvalidLayout,
        decode.FixedLayout.init(&overlap_element, .little),
    );

    // Gap: the final range ends short of the declared record size.
    const gappy = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 4, .scalar_type = .f32 },
        .{ .property_index = 1, .fixed_offset = 4, .fixed_width = 1, .scalar_type = .u8 },
    };
    const gap_element = handmadeLayout(6, &gappy);
    try std.testing.expectError(
        error.InvalidLayout,
        decode.FixedLayout.init(&gap_element, .little),
    );

    // A range extending past the record size.
    const oversized = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = 0, .fixed_width = 8, .scalar_type = .f64 },
    };
    const oversized_element = handmadeLayout(4, &oversized);
    try std.testing.expectError(
        error.InvalidLayout,
        decode.FixedLayout.init(&oversized_element, .little),
    );
}

test "a missing fixed offset is InvalidLayout" {
    const properties = [_]layout_mod.PropertyLayout{
        .{ .property_index = 0, .fixed_offset = null, .fixed_width = 4, .scalar_type = .f32 },
    };
    const element = handmadeLayout(4, &properties);
    try std.testing.expectError(
        error.InvalidLayout,
        decode.FixedLayout.init(&element, .little),
    );
}

test "an empty layout is valid with zero record size" {
    const element = handmadeLayout(0, &.{});
    const fixed = try decode.FixedLayout.init(&element, .little);
    try std.testing.expectEqual(@as(usize, 0), fixed.record_size);
}

// ---------------------------------------------------------------------------
// Encoding boundary
// ---------------------------------------------------------------------------

test "ascii encoding never reaches the binary decoder" {
    var storage = try support.parseHeader(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nend_header\n",
    );
    defer storage.deinit();
    try std.testing.expectError(
        error.UnsupportedEncoding,
        support.fixedLayout(&storage, 0, .ascii),
    );
}

// ---------------------------------------------------------------------------
// Property-level failures
// ---------------------------------------------------------------------------

test "decodeProperty rejects indices outside the schema" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var record: [4]u8 = undefined;
    support.serializeValues(fixed, &.{0x3F800000}, &record);

    try std.testing.expectError(error.InvalidPropertyIndex, decode.decodeProperty(fixed, 1, &record));
    try std.testing.expectError(
        error.InvalidPropertyIndex,
        decode.decodeProperty(fixed, std.math.maxInt(usize), &record),
    );
}

test "decodeProperty rejects records shorter than the requested range" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property double big\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    // A full record would be 12 bytes; provide a full-length buffer but
    // slice it shorter so the double at offset 4 is truncated. Property
    // 0 still decodes; property 1 reports cleanly at every short length.
    var truncated: [12]u8 = undefined;
    truncated[0] = 0x00;
    truncated[1] = 0x00;
    truncated[2] = 0x80;
    truncated[3] = 0x3F;
    @memset(truncated[4..], 0xAA);

    try std.testing.expectEqual(
        ScalarValue{ .f32 = 1.0 },
        try decode.decodeProperty(fixed, 0, truncated[0..5]),
    );
    try std.testing.expectError(
        error.InsufficientBytes,
        decode.decodeProperty(fixed, 1, truncated[0..5]),
    );

    // Every truncation length of the double is rejected (offset 4 plus
    // 0..7 bytes is always short of the property's end at 12).
    for (0..8) |length| {
        try std.testing.expectError(
            error.InsufficientBytes,
            decode.decodeProperty(fixed, 1, truncated[0 .. 4 + length]),
        );
    }
    // The full 12 bytes decode the double.
    _ = try decode.decodeProperty(fixed, 1, &truncated);
}

// ---------------------------------------------------------------------------
// Checked arithmetic
// ---------------------------------------------------------------------------

test "record range arithmetic is checked, never wrapped" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    // Count that overflows when multiplied by the 8-byte record size.
    const huge: u64 = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u64, 1), try decode.recordCountForRange(8, 8));

    const Counter = struct {
        fn consume(_: *@This(), _: u64, _: decode.RecordView) anyerror!void {}
    };
    var context: Counter = .{};
    try std.testing.expectError(
        error.SizeOverflow,
        decode.decodeRange(fixed, "", huge, &context, Counter.consume),
    );
}

test "decodeRange rejects a count larger than the input provides" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 10\n" ++
            "property uchar x\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    const Counter = struct {
        visits: u64 = 0,
        fn consume(self: *@This(), _: u64, _: decode.RecordView) anyerror!void {
            self.visits += 1;
        }
    };

    // Input holds 5 records; 10 requested.
    var bytes = [5]u8{ 1, 2, 3, 4, 5 };
    var counter = Counter{};
    try std.testing.expectError(
        error.InsufficientBytes,
        decode.decodeRange(fixed, &bytes, 10, &counter, Counter.consume),
    );
    try std.testing.expectEqual(@as(u64, 0), counter.visits);

    // Exactly 5 works.
    try decode.decodeRange(fixed, &bytes, 5, &counter, Counter.consume);
    try std.testing.expectEqual(@as(u64, 5), counter.visits);
}

// ---------------------------------------------------------------------------
// Every fixed-width bit pattern is a valid value (no phantom errors)
// ---------------------------------------------------------------------------

test "no decode error exists for arbitrary scalar bit patterns" {
    // For every canonical scalar type, an all-bits-set record and an
    // all-bits-zero record decode without error.
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 2\n" ++
            "property char a\n" ++
            "property uchar b\n" ++
            "property short c\n" ++
            "property ushort d\n" ++
            "property int e\n" ++
            "property uint f\n" ++
            "property float g\n" ++
            "property double h\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    try std.testing.expectEqual(@as(usize, 26), fixed.record_size);

    var record: [26]u8 = undefined;
    for ([2]u8{ 0x00, 0xFF }) |fill| {
        @memset(&record, fill);
        var values: [8]ScalarValue = undefined;
        try decode.decodeRecord(fixed, &record, &values);
        // NaN payloads pass through bit-exact (no normalization).
        try std.testing.expectEqual(
            @as(u64, if (fill == 0) 0 else 0xFFFFFFFFFFFFFFFF),
            values[7].bits(),
        );
    }
}
