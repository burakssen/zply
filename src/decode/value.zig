//! Typed representation of decoded scalar values.
//!
//! A decoded PLY scalar keeps the numeric type it was declared with:
//! a `property uchar red` value stays `u8`, a `property double x` value
//! stays `f64`. Converting everything to a common representation would
//! lose precision for large integers and force conversions consumers did
//! not ask for, so `ScalarValue` is a tagged union over the eight
//! canonical PLY 1.0 scalar types.
//!
//! Intended role: the value type of the *generic* decode APIs (one value
//! inspected from a record, one full record decoded into caller storage,
//! correctness tests, diagnostics). It is deliberately NOT the storage
//! format for bulk decoding: later phases decode directly into
//! homogeneous typed columns, and the primitive decoders in `scalar.zig`
//! return concrete Zig types so hot loops never touch this union.
//!
//! No implicit numeric conversion is provided. Extracting an integer as
//! a different width, or a float as an integer, is always an explicit
//! consumer decision; this module only offers lossless accessors.

const std = @import("std");
const types = @import("../format/types.zig");

const ScalarType = types.ScalarType;

/// One decoded scalar value of any canonical PLY 1.0 type.
pub const ScalarValue = union(ScalarType) {
    i8: i8,
    u8: u8,
    i16: i16,
    u16: u16,
    i32: i32,
    u32: u32,
    f32: f32,
    f64: f64,

    /// Constructs a value of the given declared type from a raw bit
    /// pattern (unsigned integer of the same width, zero-extended into
    /// `u64`). Floats are reinterpreted, never numerically converted.
    pub fn fromBits(scalar: ScalarType, pattern: u64) ScalarValue {
        return switch (scalar) {
            .i8 => .{ .i8 = @bitCast(@as(u8, @truncate(pattern))) },
            .u8 => .{ .u8 = @as(u8, @truncate(pattern)) },
            .i16 => .{ .i16 = @bitCast(@as(u16, @truncate(pattern))) },
            .u16 => .{ .u16 = @as(u16, @truncate(pattern)) },
            .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(pattern))) },
            .u32 => .{ .u32 = @as(u32, @truncate(pattern)) },
            .f32 => .{ .f32 = @bitCast(@as(u32, @truncate(pattern))) },
            .f64 => .{ .f64 = @bitCast(@as(u64, @truncate(pattern))) },
        };
    }

    /// The declared scalar type (the active tag).
    pub fn scalarType(value: ScalarValue) ScalarType {
        return @as(ScalarType, value);
    }

    /// Byte width of this value's type in a binary record.
    pub fn byteWidth(value: ScalarValue) usize {
        return value.scalarType().byteWidth();
    }

    /// The exact integer value when this is an integer-typed value,
    /// sign-extended into `i64`. No range is lost: every canonical PLY
    /// integer type fits. Floats return `null` — an integer view of a
    /// float's numeric value would be a conversion, not an access.
    pub fn intExact(value: ScalarValue) ?i64 {
        return switch (value) {
            .i8 => |v| v,
            .u8 => |v| v,
            .i16 => |v| v,
            .u16 => |v| v,
            .i32 => |v| v,
            .u32 => |v| v,
            .f32, .f64 => null,
        };
    }

    /// The exact floating-point value when this is a float-typed value,
    /// widened into `f64`. Widening `f32` to `f64` is lossless, so this
    /// remains an access, not a conversion. Integers return `null`.
    pub fn floatExact(value: ScalarValue) ?f64 {
        return switch (value) {
            .f32 => |v| v,
            .f64 => |v| v,
            else => null,
        };
    }

    /// The unsigned bit pattern of this value: the same bit sequence the
    /// value would occupy in a (little-endian, host-order) memory cell of
    /// its own width, zero-extended into `u64`. Used for bit-exact
    /// comparison and checksums.
    pub fn bits(value: ScalarValue) u64 {
        return switch (value) {
            .i8 => |v| @as(u8, @bitCast(v)),
            .u8 => |v| @as(u64, v),
            .i16 => |v| @as(u16, @bitCast(v)),
            .u16 => |v| @as(u64, v),
            .i32 => |v| @as(u32, @bitCast(v)),
            .u32 => |v| @as(u64, v),
            .f32 => |v| @as(u32, @bitCast(v)),
            .f64 => |v| @as(u64, @bitCast(v)),
        };
    }

    /// Bit-level equality, meaningful for floats where numeric equality
    /// is not: NaN never equals itself numerically, and `-0.0` equals
    /// `0.0` numerically while having different representations. Values
    /// of different types are never bit-equal.
    pub fn bitsEqual(a: ScalarValue, b: ScalarValue) bool {
        if (a.scalarType() != b.scalarType()) return false;
        return a.bits() == b.bits();
    }
};
