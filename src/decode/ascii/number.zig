//! Strict ASCII decimal conversion, shared by scalar and list decoders.
const std = @import("std");
const types = @import("../../format/types.zig");
const Value = @import("../value.zig").ScalarValue;

pub const NumberError = error{ InvalidNumber, IntegerOverflow, FloatOverflow };

pub fn parse(comptime T: type, token: []const u8) NumberError!T {
    if (token.len == 0) return error.InvalidNumber;
    switch (@typeInfo(T)) {
        .int => {
            var start: usize = 0;
            if (token[0] == '+' or token[0] == '-') {
                start = 1;
                if (start == token.len) return error.InvalidNumber;
                if (token[0] == '-' and @typeInfo(T).int.signedness == .unsigned) return error.InvalidNumber;
            }
            for (token[start..]) |c| {
                if (c < '0' or c > '9') return error.InvalidNumber;
            }
            return std.fmt.parseInt(T, token, 10) catch |err| switch (err) {
                error.Overflow => error.IntegerOverflow,
                else => error.InvalidNumber,
            };
        },
        .float => {
            if (std.mem.eql(u8, token, "nan")) return std.math.nan(T);
            if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return std.math.inf(T);
            if (std.mem.eql(u8, token, "-inf")) return -std.math.inf(T);
            var i: usize = 0;
            if (token[i] == '+' or token[i] == '-') i += 1;
            var digits: usize = 0;
            while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) digits += 1;
            if (i < token.len and token[i] == '.') {
                i += 1;
                while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) digits += 1;
            }
            if (digits == 0) return error.InvalidNumber;
            if (i < token.len and (token[i] == 'e' or token[i] == 'E')) {
                i += 1;
                if (i < token.len and (token[i] == '+' or token[i] == '-')) i += 1;
                const exponent_start = i;
                while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) {}
                if (i == exponent_start) return error.InvalidNumber;
            }
            if (i != token.len) return error.InvalidNumber;
            const value = std.fmt.parseFloat(T, token) catch return error.InvalidNumber;
            if (std.math.isInf(value)) return error.FloatOverflow;
            return value;
        },
        else => @compileError("PLY ASCII number must be an integer or float"),
    }
}

pub fn scalar(t: types.ScalarType, token: []const u8) NumberError!Value {
    return switch (t) {
        inline else => |tag| @unionInit(Value, @tagName(tag), try parse(tag.zigType(), token)),
    };
}

pub fn listCount(t: types.IntegerType, token: []const u8) (NumberError || error{ NegativeListCount, InvalidListCount })!usize {
    const v = try scalar(t.scalar(), token);
    const signed = v.intExact().?;
    if (signed < 0) return error.NegativeListCount;
    return std.math.cast(usize, @as(u64, @intCast(signed))) orelse return error.InvalidListCount;
}

test "integer grammar and ranges" {
    try std.testing.expectEqual(@as(i8, -128), try parse(i8, "-128"));
    try std.testing.expectEqual(@as(u32, 4294967295), try parse(u32, "+4294967295"));
    try std.testing.expectError(error.IntegerOverflow, parse(u8, "256"));
    try std.testing.expectError(error.InvalidNumber, parse(i32, "0x10"));
    try std.testing.expectError(error.InvalidNumber, parse(i32, "1e3"));
    try std.testing.expectError(error.InvalidNumber, parse(u8, "-1"));
}

test "floating grammar and negative zero" {
    try std.testing.expectEqual(@as(f64, 0.5), try parse(f64, ".5"));
    try std.testing.expectEqual(@as(f32, 1000), try parse(f32, "1e3"));
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(try parse(f32, "-0.0"))));
    try std.testing.expectError(error.FloatOverflow, parse(f32, "1e9999"));
    try std.testing.expectError(error.InvalidNumber, parse(f32, "1e+"));
    try std.testing.expect(std.math.isNan(try parse(f64, "nan")));
}
