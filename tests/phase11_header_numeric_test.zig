//! Phase 11 M5: header grammar, compatibility policy and ASCII numeric matrix.
//! These unit tests use only the internal module to avoid mixing module types.
const std = @import("std");
const internals = @import("zply_internals");
const number = internals.ascii.number;
const Options = internals.options.Options;

fn header(source: []const u8, options: Options) !internals.header_parser.HeaderStorage {
    var reader: std.Io.Reader = .fixed(source);
    return internals.header_parser.parseHeader(std.testing.allocator, &reader, options);
}

fn rejectHeader(source: []const u8, options: Options, expected: anyerror) !void {
    var reader: std.Io.Reader = .fixed(source);
    try std.testing.expectError(
        expected,
        internals.header_parser.parseHeader(std.testing.allocator, &reader, options),
    );
}

test "M5 indented comment and obj_info preserve the exact payload" {
    var storage = try header(
        "ply\n" ++
        "format ascii 1.0\n" ++
        "  comment  alpha  beta\n" ++
        "\tobj_info\t Dataset  A\n" ++
        " \tcomment\n" ++
        "comment tail\n" ++
        "end_header\n",
        .{},
    );
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 3), storage.header.comments.len);
    try std.testing.expectEqualStrings(" alpha  beta", storage.header.comments[0]);
    try std.testing.expectEqualStrings("", storage.header.comments[1]);
    try std.testing.expectEqualStrings("tail", storage.header.comments[2]);
    try std.testing.expectEqual(@as(usize, 1), storage.header.obj_info.len);
    try std.testing.expectEqualStrings(" Dataset  A", storage.header.obj_info[0]);
}

test "M5 accepted encodings retain canonical version and body boundary" {
    const names = [_][]const u8{ "ascii", "binary_little_endian", "binary_big_endian" };
    for (names) |encoding| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "ply\nformat {s} 1.0\nelement empty 0\nend_header\nTAIL",
            .{encoding},
        );
        defer std.testing.allocator.free(source);
        var storage = try header(source, .{});
        defer storage.deinit();
        try std.testing.expectEqual(@as(u16, 1), storage.header.version.major);
        try std.testing.expectEqual(@as(u16, 0), storage.header.version.minor);
        try std.testing.expectEqual(@as(u64, @intCast(source.len - 4)), storage.header.body_offset);
        try std.testing.expectEqual(@as(usize, 1), storage.header.elements.len);
        try std.testing.expectEqual(@as(u64, 0), storage.header.elements[0].count);
    }
}

test "M5 element counts are unsigned decimal u64 and do not allocate records" {
    var storage = try header(
        "ply\nformat ascii 1.0\nelement maximum 18446744073709551615\nend_header\n",
        .{},
    );
    defer storage.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), storage.header.elements[0].count);
    try rejectHeader("ply\nformat ascii 1.0\nelement a 18446744073709551616\nend_header\n", .{}, error.NumericOverflow);
    try rejectHeader("ply\nformat ascii 1.0\nelement a -1\nend_header\n", .{}, error.InvalidElement);
    try rejectHeader("ply\nformat ascii 1.0\nelement a +1\nend_header\n", .{}, error.InvalidElement);
    try rejectHeader("ply\nformat ascii 1.0\nelement a 1.0\nend_header\n", .{}, error.InvalidElement);
}

test "M5 strict names and compatibility aliases do not relax structural grammar" {
    const extension = "ply\nformat ascii 1.0\nelement vertex 1\nproperty FLOAT32 x\nend_header\n";
    try rejectHeader(extension, .{}, error.InvalidScalarType);
    const compatible = Options{ .strict = false };
    var storage = try header(extension, compatible);
    defer storage.deinit();
    try std.testing.expectEqual(internals.types.ScalarType.f32, storage.header.elements[0].properties[0].scalarType().?);

    // Compatibility may expand the accepted scalar names, but cannot
    // interpret a floating-point list count or an unknown directive.
    try rejectHeader(
        "ply\nformat ascii 1.0\nelement e 1\nproperty list FLOAT int ids\nend_header\n",
        compatible,
        error.InvalidListCountType,
    );
    try rejectHeader("ply\nformat ascii 1.0\nunknown x\nend_header\n", compatible, error.InvalidDirective);
    try rejectHeader("ply\nformat ASCII 1.0\nend_header\n", compatible, error.UnsupportedEncoding);
    try rejectHeader("ply\nformat ascii 1.1\nend_header\n", compatible, error.UnsupportedVersion);
}

test "M5 integer parsing preserves exact signed and unsigned limits" {
    try std.testing.expectEqual(@as(i8, -128), try number.parse(i8, "-128"));
    try std.testing.expectEqual(@as(i8, 127), try number.parse(i8, "+127"));
    try std.testing.expectEqual(@as(u8, 255), try number.parse(u8, "0255"));
    try std.testing.expectEqual(@as(i16, -32768), try number.parse(i16, "-32768"));
    try std.testing.expectEqual(@as(u16, 65535), try number.parse(u16, "65535"));
    try std.testing.expectEqual(@as(i32, -2147483648), try number.parse(i32, "-2147483648"));
    try std.testing.expectEqual(@as(u32, 4294967295), try number.parse(u32, "+4294967295"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(i8, "-129"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(i8, "128"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(u8, "256"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(i16, "32768"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(u16, "65536"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(i32, "2147483648"));
    try std.testing.expectError(error.IntegerOverflow, number.parse(u32, "4294967296"));
    for ([_][]const u8{ "", "+", "-", "1.0", "1e2", "0x10", "1_000", " 1", "1 " }) |token| {
        try std.testing.expectError(error.InvalidNumber, number.parse(i32, token));
    }
    try std.testing.expectError(error.InvalidNumber, number.parse(u8, "-1"));
    try std.testing.expectError(error.NegativeListCount, number.listCount(.i16, "-1"));
    try std.testing.expectError(error.IntegerOverflow, number.listCount(.u8, "256"));
    try std.testing.expectEqual(@as(usize, 0), try number.listCount(.u8, "0"));
}

test "M5 float syntax, negative zero, finite overflow and explicit special tokens" {
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(try number.parse(f32, "-0"))));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(try number.parse(f64, "-0.0"))));
    try std.testing.expectEqual(@as(f32, 0.5), try number.parse(f32, ".5"));
    try std.testing.expectEqual(@as(f64, 1000), try number.parse(f64, "1e3"));
    try std.testing.expectEqual(@as(f64, -0.125), try number.parse(f64, "-1.25E-1"));
    try std.testing.expect(std.math.isNan(try number.parse(f32, "nan")));
    try std.testing.expect(std.math.isInf(try number.parse(f32, "+inf")));
    try std.testing.expect((try number.parse(f64, "-inf")) < 0);
    try std.testing.expectError(error.FloatOverflow, number.parse(f32, "1e9999"));
    try std.testing.expectError(error.FloatOverflow, number.parse(f64, "-1e9999"));
    for ([_][]const u8{ "", "+", "-", ".", ".e1", "1e", "1e+", "1e-", "1.2.3", "0x1p2", "NaN", "+nan", "INF", "Infinity" }) |token| {
        try std.testing.expectError(error.InvalidNumber, number.parse(f64, token));
    }
}
