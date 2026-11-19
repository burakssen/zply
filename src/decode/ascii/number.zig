//! Strict ASCII decimal conversion, shared by scalar and list decoders.
const std = @import("std");
const types = @import("../../format/types.zig");
const Value = @import("../value.zig").ScalarValue;

pub const NumberError = error{ InvalidNumber, IntegerOverflow, FloatOverflow };

pub fn parse(comptime T: type, token: []const u8) NumberError!T {
    if (token.len == 0) return error.InvalidNumber;
    switch (@typeInfo(T)) {
        .int => return parseInteger(T, token),
        .float => {
            // Non-finite spellings are rare in numeric bodies. Checking the
            // length and first byte first avoids three string comparisons on
            // every ordinary decimal token (a measurable hot-path cost).
            switch (token.len) {
                3 => {
                    if (token[0] == 'n') {
                        if (std.mem.eql(u8, token, "nan")) return std.math.nan(T);
                    } else if (token[0] == 'i') {
                        if (std.mem.eql(u8, token, "inf")) return std.math.inf(T);
                    }
                },
                4 => {
                    if (token[0] == '+') {
                        if (std.mem.eql(u8, token, "+inf")) return std.math.inf(T);
                    } else if (token[0] == '-') {
                        if (std.mem.eql(u8, token, "-inf")) return -std.math.inf(T);
                    }
                },
                else => {},
            }

            // Phase 12 M10: combine lexical validation with mantissa and
            // exponent accumulation. When the decimal is exactly representable
            // as `mantissa * 10^net` with an exact power of ten and an exactly
            // representable mantissa, IEEE multiplication/division performs a
            // single correct rounding. Everything else falls back to the
            // standard library's correctly rounded converter.
            var i: usize = 0;
            var negative = false;
            if (token[i] == '+' or token[i] == '-') {
                negative = token[i] == '-';
                i += 1;
            }
            var mantissa: u64 = 0;
            var any_digits = false;
            var too_many_digits = false;
            while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) {
                any_digits = true;
                const digit: u64 = token[i] - '0';
                if (mantissa <= (std.math.maxInt(u64) - digit) / 10) {
                    mantissa = mantissa * 10 + digit;
                } else {
                    too_many_digits = true;
                }
            }
            var fraction_digits: i64 = 0;
            if (i < token.len and token[i] == '.') {
                i += 1;
                while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) {
                    any_digits = true;
                    const digit: u64 = token[i] - '0';
                    if (mantissa <= (std.math.maxInt(u64) - digit) / 10) {
                        mantissa = mantissa * 10 + digit;
                        fraction_digits += 1;
                    } else {
                        too_many_digits = true;
                    }
                }
            }
            if (!any_digits) return error.InvalidNumber;
            var exponent: i64 = 0;
            if (i < token.len and (token[i] == 'e' or token[i] == 'E')) {
                i += 1;
                var exponent_negative = false;
                if (i < token.len and (token[i] == '+' or token[i] == '-')) {
                    exponent_negative = token[i] == '-';
                    i += 1;
                }
                const exponent_start = i;
                while (i < token.len and token[i] >= '0' and token[i] <= '9') : (i += 1) {
                    const digit: i64 = token[i] - '0';
                    if (exponent < 1_000_000) exponent = exponent * 10 + digit;
                }
                if (i == exponent_start) return error.InvalidNumber;
                if (exponent_negative) exponent = -exponent;
            }
            if (i != token.len) return error.InvalidNumber;

            const net = exponent - fraction_digits;
            if (!too_many_digits) {
                if (fastDecimal(T, mantissa, negative, net)) |value| return value;
            }
            const value = std.fmt.parseFloat(T, token) catch return error.InvalidNumber;
            if (std.math.isInf(value)) return error.FloatOverflow;
            return value;
        },
        else => @compileError("PLY ASCII number must be an integer or float"),
    }
}

/// Converts `mantissa * 10^net` when both operands are exactly representable
/// in `T`. IEEE 754 multiplication/division then rounds the exact decimal
/// value once, so the result is identical to a correctly rounded parser.
/// Returns null when the fast path cannot prove those conditions.
fn fastDecimal(comptime T: type, mantissa: u64, negative: bool, net: i64) ?T {
    const max_exact_mantissa: u64 = switch (T) {
        f32 => 1 << 24,
        f64 => 1 << 53,
        else => @compileError("fastDecimal supports f32 and f64"),
    };
    if (mantissa > max_exact_mantissa) return null;
    const powers: []const T = switch (T) {
        f32 => &[_]f32{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10 },
        f64 => &[_]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 },
        else => unreachable,
    };
    var value: T = @floatFromInt(mantissa);
    if (net > 0) {
        if (net >= powers.len) return null;
        value *= powers[@intCast(net)];
    } else if (net < 0) {
        const scale: u64 = @intCast(-net);
        if (scale >= powers.len) return null;
        value /= powers[@intCast(scale)];
    }
    return if (negative) -value else value;
}

/// Direct decimal integer conversion for the deliberately narrow PLY
/// grammar: optional sign followed by one or more ASCII digits. This avoids
/// validating the token and then re-validating it inside a generic parser.
fn parseInteger(comptime T: type, token: []const u8) NumberError!T {
    const info = @typeInfo(T).int;
    const bits = info.bits;
    const Acc = if (bits <= 32) u64 else u128;
    var at: usize = 0;
    var negative = false;
    if (token[0] == '+' or token[0] == '-') {
        negative = token[0] == '-';
        at = 1;
        if (at == token.len) return error.InvalidNumber;
        if (negative and info.signedness == .unsigned) return error.InvalidNumber;
    }
    const limit: Acc = if (info.signedness == .signed)
        if (negative)
            @as(Acc, 1) << @intCast(bits - 1)
        else
            (@as(Acc, 1) << @intCast(bits - 1)) - 1
    else
        (@as(Acc, 1) << @intCast(bits)) - 1;

    var accumulator: Acc = 0;
    while (at < token.len) : (at += 1) {
        const ch = token[at];
        if (ch < '0' or ch > '9') return error.InvalidNumber;
        const digit: Acc = ch - '0';
        if (accumulator > (limit - digit) / 10) return error.IntegerOverflow;
        accumulator = accumulator * 10 + digit;
    }
    if (negative) {
        const signed_value: i128 = -@as(i128, @intCast(accumulator));
        return @intCast(signed_value);
    }
    return @intCast(accumulator);
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
