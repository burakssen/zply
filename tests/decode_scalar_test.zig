//! Tests for the typed scalar value representation (Task 3.2) and the
//! primitive/generic scalar decoders (Tasks 3.3–3.5): exact values,
//! boundary values, signed representations, and truncated inputs.
//!
//! Uses the internals universe exclusively.

const std = @import("std");
const support = @import("decode_support.zig");

const decode = support.decode;
const types = support.types;
const ScalarValue = support.ScalarValue;

// ---------------------------------------------------------------------------
// ScalarValue: construction and access (Task 3.2)
// ---------------------------------------------------------------------------

test "all eight canonical variants construct and access exactly" {
    // Boundary values from the phase spec, preserved without coercion.
    const cases = [_]ScalarValue{
        .{ .i8 = -128 },
        .{ .u8 = 255 },
        .{ .i16 = -32768 },
        .{ .u16 = 65535 },
        .{ .i32 = -2147483648 },
        .{ .u32 = 4294967295 },
        .{ .f32 = 1.5 },
        .{ .f64 = 1.5 },
    };

    try std.testing.expectEqual(ScalarValue{ .i8 = -128 }, cases[0]);
    try std.testing.expectEqual(@as(?i64, -128), cases[0].intExact());
    try std.testing.expectEqual(@as(?i64, -32768), cases[2].intExact());
    try std.testing.expectEqual(@as(?i64, -2147483648), cases[4].intExact());
    try std.testing.expectEqual(@as(?i64, 4294967295), cases[5].intExact());
    try std.testing.expectEqual(@as(?i64, null), cases[6].intExact());
    try std.testing.expectEqual(@as(?f64, null), cases[4].floatExact());
    try std.testing.expectEqual(@as(?f64, 1.5), cases[6].floatExact());
    try std.testing.expectEqual(@as(?f64, 1.5), cases[7].floatExact());

    // Declared type survives the round trip through the tag.
    try std.testing.expectEqual(types.ScalarType.i8, cases[0].scalarType());
    try std.testing.expectEqual(types.ScalarType.u8, cases[1].scalarType());
    try std.testing.expectEqual(types.ScalarType.i16, cases[2].scalarType());
    try std.testing.expectEqual(types.ScalarType.u16, cases[3].scalarType());
    try std.testing.expectEqual(types.ScalarType.i32, cases[4].scalarType());
    try std.testing.expectEqual(types.ScalarType.u32, cases[5].scalarType());
    try std.testing.expectEqual(types.ScalarType.f32, cases[6].scalarType());
    try std.testing.expectEqual(types.ScalarType.f64, cases[7].scalarType());

    try std.testing.expectEqual(@as(usize, 1), cases[0].byteWidth());
    try std.testing.expectEqual(@as(usize, 8), cases[7].byteWidth());
}

test "intExact preserves unsigned ranges through i64" {
    try std.testing.expectEqual(@as(?i64, 0), (ScalarValue{ .u8 = 0 }).intExact());
    try std.testing.expectEqual(@as(?i64, 65535), (ScalarValue{ .u16 = 65535 }).intExact());
    try std.testing.expectEqual(@as(?i64, 2147483647), (ScalarValue{ .i32 = 2147483647 }).intExact());
    try std.testing.expectEqual(@as(?i64, -1), (ScalarValue{ .i8 = -1 }).intExact());
    // u32 max fits i64 exactly; no wraparound into negative territory.
    try std.testing.expect(std.math.sign((ScalarValue{ .u32 = 4294967295 }).intExact().?) > 0);
}

test "bitsEqual is bit-level, not numeric" {
    // NaN is never numerically equal to itself, but bitsEqual says yes.
    const nan_a = ScalarValue{ .f32 = std.math.nan(f32) };
    const nan_b = ScalarValue{ .f32 = std.math.nan(f32) };
    try std.testing.expect(nan_a.bitsEqual(nan_b));
    try std.testing.expect(!(nan_a.f32 == nan_b.f32));

    // -0.0 and 0.0 are numerically equal with different bits.
    const pos_zero = ScalarValue{ .f64 = 0.0 };
    const neg_zero = ScalarValue{ .f64 = -0.0 };
    try std.testing.expect(pos_zero.f64 == neg_zero.f64);
    try std.testing.expect(!pos_zero.bitsEqual(neg_zero));
    try std.testing.expect(pos_zero.bitsEqual(pos_zero));
    try std.testing.expect(neg_zero.bitsEqual(neg_zero));

    // Different declared types are never bit-equal.
    try std.testing.expect(!(ScalarValue{ .u8 = 1 }).bitsEqual(.{ .i8 = 1 }));
    try std.testing.expect(!(ScalarValue{ .f32 = 1.0 }).bitsEqual(.{ .f64 = 1.0 }));
}

test "bits() exposes the exact representation for checksums" {
    try std.testing.expectEqual(@as(u64, 0x80), (ScalarValue{ .i8 = -128 }).bits());
    try std.testing.expectEqual(@as(u64, 0xFFFF), (ScalarValue{ .u16 = 0xFFFF }).bits());
    try std.testing.expectEqual(
        @as(u64, 0x3F800000),
        (ScalarValue{ .f32 = 1.0 }).bits(),
    );
    try std.testing.expectEqual(
        @as(u64, 0x3FF0000000000000),
        (ScalarValue{ .f64 = 1.0 }).bits(),
    );
    try std.testing.expectEqual(@as(u64, 0x80000000), (ScalarValue{ .i32 = -2147483648 }).bits());
}

// ---------------------------------------------------------------------------
// Primitive decoders: all integer widths, both byte orders (Task 3.3)
// ---------------------------------------------------------------------------

test "integer boundary values decode in both byte orders" {
    const cases = .{
        .{ .T = i8, .values = [_]i8{ -128, -1, 0, 127 } },
        .{ .T = u8, .values = [_]u8{ 0, 1, 127, 255 } },
        .{ .T = i16, .values = [_]i16{ -32768, -2, -1, 0, 1, 32767 } },
        .{ .T = u16, .values = [_]u16{ 0, 1, 32767, 65535 } },
        .{ .T = i32, .values = [_]i32{ -2147483648, -1, 0, 1, 2147483647 } },
        .{ .T = u32, .values = [_]u32{ 0, 1, 2147483647, 4294967295 } },
    };

    inline for (cases) |case| {
        const T = case.T;
        var buffer: [@sizeOf(T)]u8 = undefined;
        for (case.values) |value| {
            inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
                // Serialize with the reference decoder's conventions and
                // decode with the production primitive.
                const width = @sizeOf(T);
                const raw: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(value);
                const Shift = std.math.Log2Int(@Int(.unsigned, @bitSizeOf(T)));
                for (0..width) |i| {
                    const shift: Shift = @intCast(switch (endian) {
                        .little => i * 8,
                        .big => (width - 1 - i) * 8,
                    });
                    buffer[i] = @truncate(raw >> shift);
                }
                try std.testing.expectEqual(value, try decode.decodeScalarAs(T, endian, &buffer));
            }
        }
    }
}

test "signed values use two's complement in both byte orders" {
    // i16 -2: little-endian FE FF, big-endian FF FE. Both decode to -2.
    try std.testing.expectEqual(
        @as(i16, -2),
        try decode.decodeScalarAs(i16, .little, &.{ 0xFE, 0xFF }),
    );
    try std.testing.expectEqual(
        @as(i16, -2),
        try decode.decodeScalarAs(i16, .big, &.{ 0xFF, 0xFE }),
    );

    // i32 -1 in big-endian: FF FF FF FF.
    try std.testing.expectEqual(
        @as(i32, -1),
        try decode.decodeScalarAs(i32, .big, &.{ 0xFF, 0xFF, 0xFF, 0xFF }),
    );

    // The same bits read as unsigned give the expected raw pattern.
    try std.testing.expectEqual(
        @as(u16, 0xFFFE),
        try decode.decodeScalarAs(u16, .big, &.{ 0xFF, 0xFE }),
    );
}

test "one-byte types are byte-order independent" {
    try std.testing.expectEqual(
        @as(i8, -42),
        try decode.decodeScalarAs(i8, .little, &.{0xD6}),
    );
    try std.testing.expectEqual(
        @as(i8, -42),
        try decode.decodeScalarAs(i8, .big, &.{0xD6}),
    );
    try std.testing.expectEqual(
        @as(u8, 200),
        try decode.decodeScalarAs(u8, .little, &.{0xC8}),
    );
    try std.testing.expectEqual(
        @as(u8, 200),
        try decode.decodeScalarAs(u8, .big, &.{0xC8}),
    );
}

// ---------------------------------------------------------------------------
// Floating-point decoding (Task 3.4)
// ---------------------------------------------------------------------------

test "known f32/f64 patterns (written as data tables)" {
    // f32 fixtures: [value-as-bits, little bytes..., big bytes...]
    const f32_cases = [_]struct { bits: u32, little: [4]u8, big: [4]u8 }{
        .{ .bits = 0x3F800000, .little = .{ 0x00, 0x00, 0x80, 0x3F }, .big = .{ 0x3F, 0x80, 0x00, 0x00 } }, // 1.0
        .{ .bits = 0xBF800000, .little = .{ 0x00, 0x00, 0x80, 0xBF }, .big = .{ 0xBF, 0x80, 0x00, 0x00 } }, // -1.0
        .{ .bits = 0x00000000, .little = .{ 0x00, 0x00, 0x00, 0x00 }, .big = .{ 0x00, 0x00, 0x00, 0x00 } }, // +0.0
        .{ .bits = 0x80000000, .little = .{ 0x00, 0x00, 0x00, 0x80 }, .big = .{ 0x80, 0x00, 0x00, 0x00 } }, // -0.0
        .{ .bits = 0x40300000, .little = .{ 0x00, 0x00, 0x30, 0x40 }, .big = .{ 0x40, 0x30, 0x00, 0x00 } }, // 2.75
        .{ .bits = 0xC0400000, .little = .{ 0x00, 0x00, 0x40, 0xC0 }, .big = .{ 0xC0, 0x40, 0x00, 0x00 } }, // -3.0
    };
    for (f32_cases) |case| {
        const from_little = try decode.decodeScalarAs(f32, .little, &case.little);
        const from_big = try decode.decodeScalarAs(f32, .big, &case.big);
        try std.testing.expectEqual(case.bits, @as(u32, @bitCast(from_little)));
        try std.testing.expectEqual(case.bits, @as(u32, @bitCast(from_big)));
    }

    // f64 fixtures: 1.0, -1.0, 3.25, -0.0.
    const f64_cases = [_]struct { bits: u64, little: [8]u8, big: [8]u8 }{
        .{
            .bits = 0x3FF0000000000000,
            .little = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F },
            .big = .{ 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        },
        .{
            .bits = 0xBFF0000000000000,
            .little = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xBF },
            .big = .{ 0xBF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        },
        .{
            .bits = 0x400A000000000000, // 3.25
            .little = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x40 },
            .big = .{ 0x40, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        },
        .{
            .bits = 0x8000000000000000, // -0.0
            .little = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80 },
            .big = .{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        },
    };
    for (f64_cases) |case| {
        const from_little = try decode.decodeScalarAs(f64, .little, &case.little);
        const from_big = try decode.decodeScalarAs(f64, .big, &case.big);
        try std.testing.expectEqual(case.bits, @as(u64, @bitCast(from_little)));
        try std.testing.expectEqual(case.bits, @as(u64, @bitCast(from_big)));
    }
}

test "float special values preserve exact bit patterns (both endians)" {
    const f32_specials = [_]u32{
        0x00000000, // +0.0
        0x80000000, // -0.0
        0x7F800000, // +infinity
        0xFF800000, // -infinity
        0x7FC00000, // quiet NaN (default payload)
        0x7FA5A5A5, // NaN with arbitrary payload
        0xFFC00000, // negative quiet NaN
        0x00000001, // smallest subnormal
        0x007FFFFF, // largest subnormal
        0x00800000, // smallest normal
        0x7F7FFFFF, // largest finite
    };
    for (f32_specials) |bits| {
        const little_bytes = [4]u8{
            @truncate(bits),
            @truncate(bits >> 8),
            @truncate(bits >> 16),
            @truncate(bits >> 24),
        };
        const big_bytes = [4]u8{
            @truncate(bits >> 24),
            @truncate(bits >> 16),
            @truncate(bits >> 8),
            @truncate(bits),
        };
        const from_little = try decode.decodeScalarAs(f32, .little, &little_bytes);
        const from_big = try decode.decodeScalarAs(f32, .big, &big_bytes);
        try std.testing.expectEqual(bits, @as(u32, @bitCast(from_little)));
        try std.testing.expectEqual(bits, @as(u32, @bitCast(from_big)));
    }

    // f64 NaN payloads and boundary values, little-endian serialization.
    const f64_specials = [_]u64{
        0x7FF8000000000000, // quiet NaN
        0x7FF8123456789ABC, // NaN with payload
        0x7FF0000000000000, // +infinity
        0xFFF0000000000000, // -infinity
        0x0000000000000001, // smallest subnormal
        0x000FFFFFFFFFFFFF, // largest subnormal
        0x0010000000000000, // smallest normal
        0x7FEFFFFFFFFFFFFF, // largest finite
    };
    for (f64_specials) |bits| {
        var little_bytes: [8]u8 = undefined;
        for (0..8) |i| little_bytes[i] = @truncate(bits >> @as(u6, @intCast(8 * i)));
        const from_little = try decode.decodeScalarAs(f64, .little, &little_bytes);
        try std.testing.expectEqual(bits, @as(u64, @bitCast(from_little)));
    }
}

test "float decoding never numerically converts integer bits" {
    // The u32 pattern 0x40000000 as a numeric integer is 1073741824, but
    // as f32 bits it is 2.0. Decoding must reinterpret, not convert.
    const bytes = [4]u8{ 0x00, 0x00, 0x00, 0x40 };
    const value = try decode.decodeScalarAs(f32, .little, &bytes);
    try std.testing.expectEqual(@as(f32, 2.0), value);
    try std.testing.expectEqual(@as(u32, 0x40000000), @as(u32, @bitCast(value)));
}

// ---------------------------------------------------------------------------
// Generic ScalarValue dispatch (Task 3.5)
// ---------------------------------------------------------------------------

test "decodeScalar returns the declared type for every canonical scalar" {
    const expect = std.testing.expectEqual;

    try expect(ScalarValue{ .i8 = -128 }, try decode.decodeScalar(
        .i8,
        .little,
        &.{0x80},
    ));
    try expect(ScalarValue{ .u8 = 255 }, try decode.decodeScalar(
        .u8,
        .big,
        &.{0xFF},
    ));
    try expect(ScalarValue{ .i16 = -2 }, try decode.decodeScalar(
        .i16,
        .little,
        &.{ 0xFE, 0xFF },
    ));
    try expect(ScalarValue{ .u16 = 65535 }, try decode.decodeScalar(
        .u16,
        .big,
        &.{ 0xFF, 0xFF },
    ));
    try expect(ScalarValue{ .i32 = -1 }, try decode.decodeScalar(
        .i32,
        .little,
        &.{ 0xFF, 0xFF, 0xFF, 0xFF },
    ));
    try expect(ScalarValue{ .u32 = 0x12345678 }, try decode.decodeScalar(
        .u32,
        .big,
        &.{ 0x12, 0x34, 0x56, 0x78 },
    ));
    try expect(ScalarValue{ .f32 = 1.0 }, try decode.decodeScalar(
        .f32,
        .little,
        &.{ 0x00, 0x00, 0x80, 0x3F },
    ));
    try expect(ScalarValue{ .f64 = -1.0 }, try decode.decodeScalar(
        .f64,
        .big,
        &.{ 0xBF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    ));
}

test "truncated scalar inputs return InsufficientBytes at every length" {
    // f64: lengths 0..7 must all be rejected; 8 succeeds.
    var bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F };
    var length: usize = 0;
    while (length < 8) : (length += 1) {
        try std.testing.expectError(
            error.InsufficientBytes,
            decode.decodeScalarAs(f64, .little, bytes[0..length]),
        );
        try std.testing.expectError(
            error.InsufficientBytes,
            decode.decodeScalar(.f64, .little, bytes[0..length]),
        );
    }
    _ = try decode.decodeScalarAs(f64, .little, &bytes);

    // Every canonical width: one byte short is rejected, exact works.
    inline for (.{ i8, u8, i16, u16, i32, u32, f32, f64 }) |T| {
        var full: [@sizeOf(T)]u8 = @splat(0xAA);
        try std.testing.expectError(
            error.InsufficientBytes,
            decode.decodeScalarAs(T, .little, full[0 .. @sizeOf(T) - 1]),
        );
        _ = try decode.decodeScalarAs(T, .little, &full);
    }
}

test "a valid scalar prefix decodes when the slice has trailing bytes" {
    // u32 needs 4 bytes; the slice has 9. Only the prefix is consumed
    // (no state to advance; the higher layers own record structure).
    const bytes = [9]u8{ 0x78, 0x56, 0x34, 0x12, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB };
    try std.testing.expectEqual(
        @as(u32, 0x12345678),
        try decode.decodeScalarAs(u32, .little, &bytes),
    );

    // f32 1.0 followed by unrelated trailing bytes.
    const f32_bytes = [7]u8{ 0x00, 0x00, 0x80, 0x3F, 0xDE, 0xAD, 0xBE };
    try std.testing.expectEqual(
        @as(f32, 1.0),
        try decode.decodeScalarAs(f32, .little, &f32_bytes),
    );
}
