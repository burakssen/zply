//! Phase 10: every canonical integer list-count type and byte order.
const std = @import("std");
const internals = @import("zply_internals");
const decode = internals.binary_list_count.decodeListCount;
const IntegerType = internals.types.IntegerType;

fn checkCount(comptime T: type, kind: IntegerType, value: T, endian: std.builtin.Endian) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, endian);
    if (comptime @typeInfo(T).int.signedness == .signed) {
        if (value < 0) {
            try std.testing.expectError(error.NegativeListCount, decode(kind, endian, &encoded));
        } else {
            try std.testing.expectEqual(@as(usize, @intCast(value)), try decode(kind, endian, &encoded));
        }
    } else {
        try std.testing.expectEqual(@as(usize, value), try decode(kind, endian, &encoded));
    }
    for (0..@sizeOf(T)) |prefix_size| {
        try std.testing.expectError(error.InsufficientBytes, decode(kind, endian, encoded[0..prefix_size]));
    }
}

test "Phase 10 all binary list-count types reject negatives and truncated prefixes" {
    inline for (.{ .little, .big }) |endian| {
        inline for (.{ @as(i8, -128), @as(i8, -1), @as(i8, 0), @as(i8, 1), @as(i8, 127) }) |v| try checkCount(i8, .i8, v, endian);
        inline for (.{ @as(u8, 0), @as(u8, 1), @as(u8, 255) }) |v| try checkCount(u8, .u8, v, endian);
        inline for (.{ @as(i16, -32768), @as(i16, -1), @as(i16, 0), @as(i16, 32767) }) |v| try checkCount(i16, .i16, v, endian);
        inline for (.{ @as(u16, 0), @as(u16, 300), @as(u16, 65535) }) |v| try checkCount(u16, .u16, v, endian);
        inline for (.{ @as(i32, -2147483647 - 1), @as(i32, -1), @as(i32, 0), @as(i32, 2147483647) }) |v| try checkCount(i32, .i32, v, endian);
        inline for (.{ @as(u32, 0), @as(u32, 1), @as(u32, 4294967295) }) |v| {
            // usize may be narrower on 32-bit targets, but all canonical
            // u32 counts are representable there as well.
            try checkCount(u32, .u32, v, endian);
        }
    }
}

test "Phase 10 count 300 uses the declared endian, not host byte order" {
    try std.testing.expectEqual(@as(usize, 300), try decode(.u16, .little, &.{ 0x2c, 0x01 }));
    try std.testing.expectEqual(@as(usize, 300), try decode(.u16, .big, &.{ 0x01, 0x2c }));
    try std.testing.expectEqual(@as(usize, 11265), try decode(.u16, .big, &.{ 0x2c, 0x01 }));
}
