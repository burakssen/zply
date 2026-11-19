//! Phase 12 M10: differential validation of the ASCII numeric fast paths.
//! Every accepted token must produce exactly the same bits as the standard
//! library's correctly rounded converter, or the same documented error.
const std = @import("std");
const internals = @import("zply_internals");

const number = internals.ascii.number;

fn expectSame(comptime T: type, token: []const u8) !void {
    const expected = std.fmt.parseFloat(T, token) catch {
        return error.UnexpectedInvalidReference;
    };
    if (std.math.isInf(expected)) {
        try std.testing.expectError(error.FloatOverflow, number.parse(T, token));
        return;
    }
    const actual = try number.parse(T, token);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    try std.testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(actual)));
}

fn expectSameBoth(token: []const u8) !void {
    try expectSame(f32, token);
    try expectSame(f64, token);
}

fn appendDigits(buffer: []u8, at: *usize, count: usize, digit: u8) void {
    for (0..count) |_| {
        buffer[at.*] = digit;
        at.* += 1;
    }
}

test "M10 fast decimal path matches the reference converter" {
    var buffer: [128]u8 = undefined;

    // Small mantissas, varying fractional precision, and exact/inexact
    // power-of-ten scaling in both directions.
    for (0..400) |value| {
        for (0..4) |fraction_digits| {
            const fraction = value % ([_]usize{ 1, 10, 100, 1000 })[fraction_digits];
            for ([_]i32{ -24, -12, -3, -1, 0, 1, 3, 12, 24 }) |exponent| {
                const token = try std.fmt.bufPrint(&buffer, "{d}.{d}e{d}", .{ value, fraction, exponent });
                try expectSameBoth(token);
            }
        }
    }

    // Exactly representable boundary values and signed zero.
    for ([_][]const u8{
        "0",         "-0",          "0.0",         "-0.0",        "+0.0",
        "1",         "-1",          "1.",          ".5",          "-.5",
        "16777215",  "16777216",    "16777217",    "9007199254740991",
        "9007199254740992",         "9007199254740993",
        "1e22",      "1e23",        "1e-22",       "1e-23",       "1e308",
        "1e309",     "1e-308",      "1e-320",      "1e-324",      "1e-400",
        "1.7976931348623157e308",   "3.4028235e38", "3.4028236e38",
        "1.25",      "-2.5",        "3.75",        "1.0e-10",     "-2.5e-10",
        "0.1",       "0.2",         "0.3",         "0.30000000000000004",
        "123456789.123456",         "1234567890123456.0",
        "12345678901234567.0",      "123456789012345678901234567890.0",
        "1e9999",    "-1e9999",     "1e-9999",
    }) |token| {
        try expectSameBoth(token);
    }
}

test "M10 fast decimal path agrees on randomized short decimals" {
    var prng = std.Random.DefaultPrng.init(0x5eed_12aa);
    const random = prng.random();
    var buffer: [160]u8 = undefined;

    for (0..20000) |_| {
        const negative = random.boolean();
        const integer_digits = random.intRangeAtMost(usize, 1, 9);
        const fraction_digits = random.intRangeAtMost(usize, 0, 9);
        const exponent = random.intRangeAtMost(i32, -40, 40);

        var at: usize = 0;
        if (negative) {
            buffer[at] = '-';
            at += 1;
        }
        appendDigits(&buffer, &at, integer_digits, @intCast('0' + random.intRangeAtMost(u8, 0, 9)));
        if (fraction_digits > 0) {
            buffer[at] = '.';
            at += 1;
            appendDigits(&buffer, &at, fraction_digits, @intCast('0' + random.intRangeAtMost(u8, 0, 9)));
        }
        if (exponent != 0) {
            buffer[at] = 'e';
            at += 1;
            const written = try std.fmt.bufPrint(buffer[at..], "{d}", .{exponent});
            at += written.len;
        }
        try expectSameBoth(buffer[0..at]);
    }
}

test "M10 integer parser preserves range and grammar errors" {
    try std.testing.expectEqual(@as(i8, -128), try number.parse(i8, "-128"));
    try std.testing.expectEqual(@as(i8, 127), try number.parse(i8, "+127"));
    try std.testing.expectEqual(@as(u32, 4294967295), try number.parse(u32, "4294967295"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(i8, "128"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(i8, "-129"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(u32, "4294967296"));
    try std.testing.expectError(error.InvalidNumber, number.parse(i32, ""));
    try std.testing.expectError(error.InvalidNumber, number.parse(i32, "+"));
    try std.testing.expectError(error.InvalidNumber, number.parse(i32, "1_000"));
    try std.testing.expectError(error.InvalidNumber, number.parse(i32, "1e3"));
    try std.testing.expectError(error.InvalidNumber, number.parse(u8, "-1"));
}
