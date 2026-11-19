//! Fixed-width record decoding tests (Tasks 3.6–3.8): mixed-property
//! fixtures, unaligned layouts, unusual property order, zero-property
//! elements, variable-length rejection, output contracts, and RecordView
//! on-demand access.
//!
//! Uses the internals universe exclusively.

const std = @import("std");
const support = @import("decode_support.zig");

const decode = support.decode;
const types = support.types;
const ScalarValue = support.ScalarValue;

// ---------------------------------------------------------------------------
// Fixture A — XYZ with RGB (15-byte record, mixed widths)
// ---------------------------------------------------------------------------

test "fixture A: XYZRGB record decodes every field (little-endian)" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "property uchar red\n" ++
            "property uchar green\n" ++
            "property uchar blue\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    try std.testing.expectEqual(@as(usize, 15), fixed.record_size);

    // Serialize the expected values with the reference conventions.
    var record: [15]u8 = undefined;
    support.serializeValues(fixed, &.{
        0x3F800000, // x = 1.0
        0x40000000, // y = 2.0
        0x40400000, // z = 3.0
        255, // red
        128, // green
        64, // blue
    }, &record);

    var values: [6]ScalarValue = undefined;
    try decode.decodeRecord(fixed, &record, &values);

    try std.testing.expectEqual(ScalarValue{ .f32 = 1.0 }, values[0]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 2.0 }, values[1]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 3.0 }, values[2]);
    try std.testing.expectEqual(ScalarValue{ .u8 = 255 }, values[3]);
    try std.testing.expectEqual(ScalarValue{ .u8 = 128 }, values[4]);
    try std.testing.expectEqual(ScalarValue{ .u8 = 64 }, values[5]);
}

test "fixture A: the same values decode in big-endian form" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_big_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "property uchar red\n" ++
            "property uchar green\n" ++
            "property uchar blue\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_big_endian);

    var record: [15]u8 = undefined;
    support.serializeValues(fixed, &.{
        0x3F800000, 0x40000000, 0x40400000, 255, 128, 64,
    }, &record);

    var values: [6]ScalarValue = undefined;
    try decode.decodeRecord(fixed, &record, &values);
    try std.testing.expectEqual(ScalarValue{ .f32 = 1.0 }, values[0]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 3.0 }, values[2]);
    try std.testing.expectEqual(ScalarValue{ .u8 = 128 }, values[4]);
}

// ---------------------------------------------------------------------------
// Fixture B — unaligned values (flag, double at offset 1, short at 9)
// ---------------------------------------------------------------------------

test "fixture B: unaligned mixed-width record decodes without alignment assumptions" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element custom 1\n" ++
            "property uchar flag\n" ++
            "property double position\n" ++
            "property short category\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    // Layout: flag@0 (1), position@1 (8), category@9 (2) = 11 bytes.
    try std.testing.expectEqual(@as(usize, 11), fixed.record_size);
    try std.testing.expectEqual(@as(?usize, 1), fixed.element.properties[1].fixed_offset);
    try std.testing.expectEqual(@as(?usize, 9), fixed.element.properties[2].fixed_offset);

    var record: [11]u8 = undefined;
    support.serializeValues(fixed, &.{
        7, // flag
        0x4008000000000000, // position = 3.0
        0xFFFE, // category = -2
    }, &record);

    var values: [3]ScalarValue = undefined;
    try decode.decodeRecord(fixed, &record, &values);
    try std.testing.expectEqual(ScalarValue{ .u8 = 7 }, values[0]);
    try std.testing.expectEqual(ScalarValue{ .f64 = 3.0 }, values[1]);
    try std.testing.expectEqual(ScalarValue{ .i16 = -2 }, values[2]);

    // Selective access gives identical results.
    const view = try decode.RecordView.init(fixed, &record);
    try std.testing.expectEqual(ScalarValue{ .f64 = 3.0 }, try view.get(1));
    try std.testing.expectEqual(ScalarValue{ .i16 = -2 }, try view.get(2));
}

// ---------------------------------------------------------------------------
// Fixture C — unusual property ordering
// ---------------------------------------------------------------------------

test "fixture C: arbitrary property order decodes by declared layout" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property uchar blue\n" ++
            "property double z\n" ++
            "property int classification\n" ++
            "property float x\n" ++
            "property uchar red\n" ++
            "property double y\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    try std.testing.expectEqual(@as(usize, 1 + 8 + 4 + 4 + 1 + 8), fixed.record_size);

    var record: [26]u8 = undefined;
    support.serializeValues(fixed, &.{
        12, // blue
        0x4010000000000000, // z = 4.0
        0xFFFFFFFB, // classification = -5
        0x3FC00000, // x = 1.5
        200, // red
        0x4020000000000000, // y = 8.0
    }, &record);

    var values: [6]ScalarValue = undefined;
    try decode.decodeRecord(fixed, &record, &values);
    try std.testing.expectEqual(ScalarValue{ .u8 = 12 }, values[0]);
    try std.testing.expectEqual(ScalarValue{ .f64 = 4.0 }, values[1]);
    try std.testing.expectEqual(ScalarValue{ .i32 = -5 }, values[2]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 1.5 }, values[3]);
    try std.testing.expectEqual(ScalarValue{ .u8 = 200 }, values[4]);
    try std.testing.expectEqual(ScalarValue{ .f64 = 8.0 }, values[5]);
}

// ---------------------------------------------------------------------------
// Fixture D — custom element type
// ---------------------------------------------------------------------------

test "fixture D: a custom sensor element decodes exactly like vertex" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element sensor 1\n" ++
            "property uint timestamp\n" ++
            "property double temperature\n" ++
            "property ushort status\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    try std.testing.expectEqualStrings("sensor", storage.header.elements[0].name);

    var record: [14]u8 = undefined;
    support.serializeValues(fixed, &.{
        0x0000_0064, // timestamp = 100
        0xC004000000000000, // temperature = -2.5
        0x0102, // status = 258
    }, &record);

    var values: [3]ScalarValue = undefined;
    try decode.decodeRecord(fixed, &record, &values);
    try std.testing.expectEqual(ScalarValue{ .u32 = 100 }, values[0]);
    try std.testing.expectEqual(ScalarValue{ .f64 = -2.5 }, values[1]);
    try std.testing.expectEqual(ScalarValue{ .u16 = 258 }, values[2]);
}

// ---------------------------------------------------------------------------
// Fixture E — zero-property element
// ---------------------------------------------------------------------------

test "fixture E: a zero-property record is a valid no-op" {
    var storage = try support.parseHeader(
        "ply\nformat binary_little_endian 1.0\nelement empty 10\nend_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    try std.testing.expectEqual(@as(usize, 0), fixed.record_size);
    try std.testing.expectEqual(@as(usize, 0), fixed.propertyCount());

    // Zero bytes of input, zero output values: complete success.
    var values = [_]ScalarValue{.{ .i8 = 99 }};
    try std.testing.expectError(
        error.InvalidOutputLength,
        decode.decodeRecord(fixed, "", &values),
    );
    try decode.decodeRecord(fixed, "", &[_]ScalarValue{});

    // decodeProperty on a nonexistent index is still an index error.
    try std.testing.expectError(
        error.InvalidPropertyIndex,
        decode.decodeProperty(fixed, 0, ""),
    );
}

// ---------------------------------------------------------------------------
// Fixture F — variable-length rejection
// ---------------------------------------------------------------------------

test "fixture F: list-containing layouts are rejected by fixed-width APIs" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element face 1\n" ++
            "property list uchar int vertex_indices\n" ++
            "end_header\n",
    );
    defer storage.deinit();

    try std.testing.expectEqual(
        @as(?usize, null),
        storage.layouts[0].fixed_record_size,
    );

    // Constructing a fixed layout is the rejection point.
    try std.testing.expectError(
        error.VariableLengthElement,
        decode.FixedLayout.initForEncoding(&storage.layouts[0], .binary_little_endian),
    );

    // The same layout decoded as big-endian fails identically.
    try std.testing.expectError(
        error.VariableLengthElement,
        decode.FixedLayout.initForEncoding(&storage.layouts[0], .binary_big_endian),
    );
}

// ---------------------------------------------------------------------------
// decodeProperty (Task 3.6)
// ---------------------------------------------------------------------------

test "decodeProperty works independently per compiled index" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "property uchar red\n" ++
            "property uchar green\n" ++
            "property uchar blue\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var record: [15]u8 = undefined;
    support.serializeValues(
        fixed,
        &.{ 0x3F800000, 0x40000000, 0x40400000, 255, 128, 64 },
        &record,
    );

    // Selective projection: decode 0, 1, 2 and skip the colors entirely.
    try std.testing.expectEqual(ScalarValue{ .f32 = 1.0 }, try decode.decodeProperty(fixed, 0, &record));
    try std.testing.expectEqual(ScalarValue{ .f32 = 2.0 }, try decode.decodeProperty(fixed, 1, &record));
    try std.testing.expectEqual(ScalarValue{ .f32 = 3.0 }, try decode.decodeProperty(fixed, 2, &record));
    try std.testing.expectEqual(ScalarValue{ .u8 = 255 }, try decode.decodeProperty(fixed, 3, &record));

    // Works on prefixes (only the requested range must be present)...
    try std.testing.expectEqual(
        ScalarValue{ .f32 = 1.0 },
        try decode.decodeProperty(fixed, 0, record[0..4]),
    );
    // ...and on buffers that hold several records (record 3 starts at 45).
    var multi: [75]u8 = undefined;
    for (0..5) |ri| {
        support.serializeValues(
            fixed,
            &.{ 0x3F800000 + @as(u64, ri), 0x40000000, 0x40400000, 255, 128, 64 },
            multi[ri * 15 ..][0..15],
        );
    }
    // Property 0 of record 3: bits 0x3F800003.
    const from_multi = try decode.decodeProperty(fixed, 0, multi[45..]);
    try std.testing.expectEqual(
        @as(u32, 0x3F800003),
        @as(u32, @bitCast(from_multi.f32)),
    );

    // Out-of-range indices are controlled errors.
    try std.testing.expectError(error.InvalidPropertyIndex, decode.decodeProperty(fixed, 6, &record));
    try std.testing.expectError(
        error.InvalidPropertyIndex,
        decode.decodeProperty(fixed, 1 << 62, &record),
    );
}

// ---------------------------------------------------------------------------
// decodeRecord contract (Task 3.7)
// ---------------------------------------------------------------------------

test "decodeRecord validates all dimensions before writing any value" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property uchar red\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var record: [5]u8 = undefined;
    support.serializeValues(fixed, &.{ 0x3F800000, 77 }, &record);

    const sentinel = ScalarValue{ .i32 = 0x51515151 };

    // Output too small: explicit error, output untouched.
    var small = [_]ScalarValue{sentinel};
    try std.testing.expectError(
        error.InvalidOutputLength,
        decode.decodeRecord(fixed, &record, &small),
    );
    try std.testing.expectEqual(sentinel, small[0]);

    // Output too large: explicit error, output untouched.
    var large = [_]ScalarValue{ sentinel, sentinel, sentinel };
    try std.testing.expectError(
        error.InvalidOutputLength,
        decode.decodeRecord(fixed, &record, &large),
    );
    for (large) |v| try std.testing.expectEqual(sentinel, v);

    // Record too short: error, output untouched.
    var values = [_]ScalarValue{ sentinel, sentinel };
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode.decodeRecord(fixed, record[0..4], &values),
    );
    // Record too long: also an error under the exact-length contract.
    var padded: [6]u8 = undefined;
    @memcpy(padded[0..5], &record);
    padded[5] = 0;
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode.decodeRecord(fixed, &padded, &values),
    );
    for (values) |v| try std.testing.expectEqual(sentinel, v);

    // Correct dimensions decode in place.
    try decode.decodeRecord(fixed, &record, &values);
    try std.testing.expectEqual(ScalarValue{ .f32 = 1.0 }, values[0]);
    try std.testing.expectEqual(ScalarValue{ .u8 = 77 }, values[1]);
}

// ---------------------------------------------------------------------------
// RecordView (Task 3.8)
// ---------------------------------------------------------------------------

test "RecordView decodes selected properties without materializing the rest" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "property float w\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var record: [16]u8 = undefined;
    support.serializeValues(
        fixed,
        &.{ 0x3F800000, 0x40000000, 0x40400000, 0x40800000 },
        &record,
    );

    const view = try decode.RecordView.init(fixed, &record);
    try std.testing.expectEqual(@as(usize, 4), view.propertyCount());

    // Only the requested properties are decoded.
    try std.testing.expectEqual(ScalarValue{ .f32 = 2.0 }, try view.get(1));
    try std.testing.expectEqual(ScalarValue{ .f32 = 4.0 }, try view.get(3));
    try std.testing.expectEqual(ScalarValue{ .f32 = 1.0 }, try view.get(0));

    // decodeAll writes every property, exactly.
    var all: [4]ScalarValue = undefined;
    try view.decodeAll(&all);
    try std.testing.expectEqual(ScalarValue{ .f32 = 1.0 }, all[0]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 2.0 }, all[1]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 3.0 }, all[2]);
    try std.testing.expectEqual(ScalarValue{ .f32 = 4.0 }, all[3]);

    // Wrong output size is an explicit error.
    try std.testing.expectError(
        error.InvalidOutputLength,
        view.decodeAll(all[0..3]),
    );

    // Index errors.
    try std.testing.expectError(error.InvalidPropertyIndex, view.get(4));

    // Construction validates the record length once.
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode.RecordView.init(fixed, record[0..12]),
    );
}

test "RecordView is a small non-owning value type" {
    // No heap, no dispatch tables: three words (layout pointer, size,
    // endian) plus the byte slice.
    try std.testing.expect(@sizeOf(decode.RecordView) <= @sizeOf(usize) * 5);
}
