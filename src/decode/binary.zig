//! Binary encoding dispatch: PLY `Encoding` → byte order, and the
//! type-driven scalar decode API.
//!
//! This module is the seam between the PLY format model (Task 3.5) and
//! the primitive byte decoders (`scalar.zig`). The higher layers convert
//! the header's encoding once (`.little`/`.big`, rejecting `ascii`) and
//! then never mention encodings again — every primitive below this point
//! takes a plain `std.builtin.Endian`.
//!
//! `decodeScalar` dispatches on the declared `ScalarType` and returns a
//! `ScalarValue` preserving the declared numeric type. It validates that
//! the input holds enough bytes for the chosen type and nothing more:
//! record structure is the record decoder's responsibility.

const std = @import("std");
const types = @import("../format/types.zig");
const scalar = @import("scalar.zig");
const value_mod = @import("value.zig");

const ScalarType = types.ScalarType;
const Encoding = types.Encoding;
const ScalarValue = value_mod.ScalarValue;

/// Errors shared across the whole binary decoder. Individual functions
/// declare only the errors they can actually produce.
pub const DecodeError = error{
    /// A scalar, property, or record needs more input bytes.
    InsufficientBytes,
    /// ASCII (or another non-binary encoding) reached the binary decoder.
    UnsupportedEncoding,
};

/// Byte order for a binary PLY encoding, or `UnsupportedEncoding` for
/// `ascii` (which has no byte order and is decoded by the ASCII parser
/// in a later phase, never by this engine).
pub fn endianFor(encoding: Encoding) DecodeError!std.builtin.Endian {
    return switch (encoding) {
        .binary_little_endian => .little,
        .binary_big_endian => .big,
        .ascii => error.UnsupportedEncoding,
    };
}

/// Decodes one scalar of the declared PLY type from the beginning of
/// `bytes`, using the declared byte order.
///
/// The result preserves the declared type: `.f32` in yields `.f32` out.
/// Float bit patterns (including NaN payloads, infinities, subnormals,
/// and negative zero) are preserved exactly. Only `InsufficientBytes`
/// can fail — every possible bit pattern of a canonical scalar type is
/// a valid value, so there is no "invalid scalar" error.
pub fn decodeScalar(
    scalar_type: ScalarType,
    endian: std.builtin.Endian,
    bytes: []const u8,
) error{InsufficientBytes}!ScalarValue {
    switch (scalar_type) {
        inline .i8, .u8, .i16, .u16, .i32, .u32, .f32, .f64 => |tag| {
            const T = tag.zigType();
            const decoded = try scalar.decodeScalar(T, endian, bytes);
            return @unionInit(ScalarValue, @tagName(tag), decoded);
        },
    }
}

/// Decodes one scalar directly into its concrete Zig type — the hot-path
/// primitive for later column-oriented decoding, where the declared type
/// is compile-time known and no `ScalarValue` should be materialized.
pub fn decodeScalarAs(
    comptime T: type,
    endian: std.builtin.Endian,
    bytes: []const u8,
) error{InsufficientBytes}!T {
    return scalar.decodeScalar(T, endian, bytes);
}

test "endianFor maps encodings and rejects ascii" {
    try std.testing.expectEqual(
        std.builtin.Endian.little,
        try endianFor(.binary_little_endian),
    );
    try std.testing.expectEqual(
        std.builtin.Endian.big,
        try endianFor(.binary_big_endian),
    );
    try std.testing.expectError(error.UnsupportedEncoding, endianFor(.ascii));
}

test "decodeScalar dispatches every canonical type (little-endian)" {
    // Independent byte fixtures with known values.
    try std.testing.expectEqual(
        ScalarValue{ .i8 = -42 },
        try decodeScalar(.i8, .little, &.{0xD6}),
    );
    try std.testing.expectEqual(
        ScalarValue{ .u8 = 255 },
        try decodeScalar(.u8, .little, &.{0xFF}),
    );
    try std.testing.expectEqual(
        ScalarValue{ .i16 = -2 },
        try decodeScalar(.i16, .little, &.{ 0xFE, 0xFF }),
    );
    try std.testing.expectEqual(
        ScalarValue{ .u16 = 65535 },
        try decodeScalar(.u16, .little, &.{ 0xFF, 0xFF }),
    );
    try std.testing.expectEqual(
        ScalarValue{ .i32 = -2 },
        try decodeScalar(.i32, .little, &.{ 0xFE, 0xFF, 0xFF, 0xFF }),
    );
    try std.testing.expectEqual(
        ScalarValue{ .u32 = 0x12345678 },
        try decodeScalar(.u32, .little, &.{ 0x78, 0x56, 0x34, 0x12 }),
    );
    try std.testing.expectEqual(
        ScalarValue{ .f32 = 1.0 },
        try decodeScalar(.f32, .little, &.{ 0x00, 0x00, 0x80, 0x3F }),
    );
    try std.testing.expectEqual(
        ScalarValue{ .f64 = 1.0 },
        try decodeScalar(
            .f64,
            .little,
            &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F },
        ),
    );
}

test "decodeScalar rejects insufficient input" {
    try std.testing.expectError(
        error.InsufficientBytes,
        decodeScalar(.u32, .little, &.{ 0x78, 0x56, 0x34 }),
    );
    try std.testing.expectError(error.InsufficientBytes, decodeScalar(.u8, .little, &.{}));
}
