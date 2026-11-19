//! Phase 10: interpret typed list counts in either binary byte order.
//!
//! Input is a borrowed byte slice, never the original Reader. No allocation,
//! pointer-alignment assumption, or host-endianness dependence is involved.

const std = @import("std");
const types = @import("../../format/types.zig");
const scalar = @import("../scalar.zig");

pub const CountError = error{
    /// Not enough bytes to read the declared count prefix.
    InsufficientBytes,
    /// Signed counts must be nonnegative.
    NegativeListCount,
    /// The nonnegative count cannot be represented by usize.
    CountOverflow,
};

pub fn decodeListCount(
    count_type: types.IntegerType,
    endian: std.builtin.Endian,
    bytes: []const u8,
) CountError!usize {
    return switch (count_type) {
        .i8 => normalize(try scalar.decodeScalar(i8, endian, bytes)),
        .u8 => normalize(try scalar.decodeScalar(u8, endian, bytes)),
        .i16 => normalize(try scalar.decodeScalar(i16, endian, bytes)),
        .u16 => normalize(try scalar.decodeScalar(u16, endian, bytes)),
        .i32 => normalize(try scalar.decodeScalar(i32, endian, bytes)),
        .u32 => normalize(try scalar.decodeScalar(u32, endian, bytes)),
    };
}

fn normalize(value: anytype) CountError!usize {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T).int.signedness == .signed) {
        if (value < 0) return error.NegativeListCount;
    }
    return std.math.cast(usize, value) orelse return error.CountOverflow;
}
