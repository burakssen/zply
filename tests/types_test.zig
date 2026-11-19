//! Foundational tests for the PLY encoding model, version representation,
//! and the scalar type system (test groups A and B).

const std = @import("std");
const ply = @import("zply");

// ---------------------------------------------------------------------------
// Group A — Encoding
// ---------------------------------------------------------------------------

test "ascii encoding: not binary, byte order none" {
    const encoding: ply.Encoding = .ascii;
    try std.testing.expect(!encoding.isBinary());
    try std.testing.expectEqual(ply.Encoding.ByteOrder.none, encoding.byteOrder());
    try std.testing.expectEqualStrings("ascii", encoding.formatName());
}

test "little-endian encoding: binary and little-endian" {
    const encoding: ply.Encoding = .binary_little_endian;
    try std.testing.expect(encoding.isBinary());
    try std.testing.expectEqual(ply.Encoding.ByteOrder.little, encoding.byteOrder());
    try std.testing.expectEqualStrings("binary_little_endian", encoding.formatName());
}

test "big-endian encoding: binary and big-endian" {
    const encoding: ply.Encoding = .binary_big_endian;
    try std.testing.expect(encoding.isBinary());
    try std.testing.expectEqual(ply.Encoding.ByteOrder.big, encoding.byteOrder());
    try std.testing.expectEqualStrings("binary_big_endian", encoding.formatName());
}

test "canonical format names map exactly and case-sensitively" {
    try std.testing.expectEqual(ply.Encoding.ascii, try ply.Encoding.fromFormatName("ascii"));
    try std.testing.expectEqual(
        ply.Encoding.binary_little_endian,
        try ply.Encoding.fromFormatName("binary_little_endian"),
    );
    try std.testing.expectEqual(
        ply.Encoding.binary_big_endian,
        try ply.Encoding.fromFormatName("binary_big_endian"),
    );

    try std.testing.expectError(error.UnknownFormatName, ply.Encoding.fromFormatName("Ascii"));
    try std.testing.expectError(
        error.UnknownFormatName,
        ply.Encoding.fromFormatName("binary-little-endian"),
    );
    try std.testing.expectError(error.UnknownFormatName, ply.Encoding.fromFormatName(""));
    try std.testing.expectError(error.UnknownFormatName, ply.Encoding.fromFormatName("gz"));
}

test "version representation preserves exact values" {
    const v: ply.Version = .{ .major = 1, .minor = 0 };
    try std.testing.expectEqual(@as(u16, 1), v.major);
    try std.testing.expectEqual(@as(u16, 0), v.minor);

    const v2: ply.Version = .{ .major = 3, .minor = 27 };
    try std.testing.expectEqual(@as(u16, 3), v2.major);
    try std.testing.expectEqual(@as(u16, 27), v2.minor);
}

test "version policy: 1.0 supported, others representable but unsupported" {
    try std.testing.expect(ply.Header.isSupportedVersion(.{ .major = 1, .minor = 0 }));
    // 2.0 is representable as a Version, but the parser policy rejects it.
    try std.testing.expect(!ply.Header.isSupportedVersion(.{ .major = 2, .minor = 0 }));
    try std.testing.expect(!ply.Header.isSupportedVersion(.{ .major = 1, .minor = 1 }));
    try std.testing.expect(!ply.Header.isSupportedVersion(.{ .major = 0, .minor = 9 }));
    try std.testing.expectEqual(
        ply.Version{ .major = 1, .minor = 0 },
        ply.Header.supported_version,
    );
}

// ---------------------------------------------------------------------------
// Group B — Scalar types
// ---------------------------------------------------------------------------

test "all eight scalar widths" {
    try std.testing.expectEqual(@as(usize, 1), ply.ScalarType.i8.byteWidth());
    try std.testing.expectEqual(@as(usize, 1), ply.ScalarType.u8.byteWidth());
    try std.testing.expectEqual(@as(usize, 2), ply.ScalarType.i16.byteWidth());
    try std.testing.expectEqual(@as(usize, 2), ply.ScalarType.u16.byteWidth());
    try std.testing.expectEqual(@as(usize, 4), ply.ScalarType.i32.byteWidth());
    try std.testing.expectEqual(@as(usize, 4), ply.ScalarType.u32.byteWidth());
    try std.testing.expectEqual(@as(usize, 4), ply.ScalarType.f32.byteWidth());
    try std.testing.expectEqual(@as(usize, 8), ply.ScalarType.f64.byteWidth());
    try std.testing.expectEqual(@as(usize, 8), ply.ScalarType.max_width);
}

test "integer vs floating classification" {
    try std.testing.expect(ply.ScalarType.i32.isInteger());
    try std.testing.expect(!ply.ScalarType.i32.isFloating());
    try std.testing.expect(ply.ScalarType.f32.isFloating());
    try std.testing.expect(!ply.ScalarType.f32.isInteger());
    try std.testing.expect(ply.ScalarType.f64.isFloating());
    try std.testing.expect(!ply.ScalarType.f64.isInteger());
}

test "signedness classification" {
    try std.testing.expect(ply.ScalarType.i8.isSigned());
    try std.testing.expect(!ply.ScalarType.u8.isSigned());
    try std.testing.expect(ply.ScalarType.i16.isSigned());
    try std.testing.expect(!ply.ScalarType.u16.isSigned());
    try std.testing.expect(ply.ScalarType.i32.isSigned());
    try std.testing.expect(!ply.ScalarType.u32.isSigned());
    try std.testing.expect(!ply.ScalarType.f32.isSigned());
    try std.testing.expect(!ply.ScalarType.f64.isSigned());
}

test "canonical PLY names" {
    try std.testing.expectEqualStrings("char", ply.ScalarType.i8.name());
    try std.testing.expectEqualStrings("uchar", ply.ScalarType.u8.name());
    try std.testing.expectEqualStrings("short", ply.ScalarType.i16.name());
    try std.testing.expectEqualStrings("ushort", ply.ScalarType.u16.name());
    try std.testing.expectEqualStrings("int", ply.ScalarType.i32.name());
    try std.testing.expectEqualStrings("uint", ply.ScalarType.u32.name());
    try std.testing.expectEqualStrings("float", ply.ScalarType.f32.name());
    try std.testing.expectEqualStrings("double", ply.ScalarType.f64.name());
}

test "canonical name lookup round-trips for every scalar" {
    const info = @typeInfo(ply.ScalarType).@"enum";
    inline for (info.field_names) |field_name| {
        const scalar = @field(ply.ScalarType, field_name);
        try std.testing.expectEqual(scalar, try ply.ScalarType.fromName(scalar.name()));
    }
}

test "standard PLY integer aliases are strict names" {
    try std.testing.expectEqual(ply.ScalarType.i8, try ply.ScalarType.fromName("int8"));
    try std.testing.expectEqual(ply.ScalarType.u8, try ply.ScalarType.fromName("uint8"));
    try std.testing.expectEqual(ply.ScalarType.i16, try ply.ScalarType.fromName("int16"));
    try std.testing.expectEqual(ply.ScalarType.u16, try ply.ScalarType.fromName("uint16"));
    try std.testing.expectEqual(ply.ScalarType.i32, try ply.ScalarType.fromName("int32"));
    try std.testing.expectEqual(ply.ScalarType.u32, try ply.ScalarType.fromName("uint32"));
}

test "name lookup is case-sensitive in strict mode" {
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("Float"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("INT"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("UCHAR"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("float32"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("i64"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("u64"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName(""));
}

test "compatible name lookup is case-insensitive" {
    try std.testing.expectEqual(
        ply.ScalarType.f32,
        try ply.ScalarType.fromNameCompatible("FLOAT"),
    );
    try std.testing.expectEqual(
        ply.ScalarType.u8,
        try ply.ScalarType.fromNameCompatible("UChar"),
    );
    try std.testing.expectError(
        error.UnknownScalarType,
        ply.ScalarType.fromNameCompatible("i64"),
    );
}

test "invalid scalar name lookup errors" {
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("blob"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("charx"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("int64"));
    try std.testing.expectError(error.UnknownScalarType, ply.ScalarType.fromName("f16"));
}

test "integer/scalar conversion: floats rejected, integers convert" {
    // f32 -> IntegerType must fail.
    try std.testing.expectError(
        error.NotAnIntegerType,
        ply.ScalarType.f32.toIntegerType(),
    );
    try std.testing.expectError(
        error.NotAnIntegerType,
        ply.IntegerType.fromScalar(.f64),
    );

    // Every integer scalar converts, preserving identity and width.
    const integers = [_]ply.IntegerType{ .i8, .u8, .i16, .u16, .i32, .u32 };
    for (integers) |integer| {
        const scalar = integer.scalar();
        try std.testing.expect(scalar.isInteger());
        try std.testing.expectEqual(
            integer,
            try ply.ScalarType.toIntegerType(scalar),
        );
        try std.testing.expectEqual(
            integer,
            try ply.IntegerType.fromScalar(scalar),
        );
        try std.testing.expectEqual(integer.byteWidth(), scalar.byteWidth());
    }
}

test "scalar zigType matches byte width" {
    try std.testing.expectEqual(i8, ply.ScalarType.i8.zigType());
    try std.testing.expectEqual(u8, ply.ScalarType.u8.zigType());
    try std.testing.expectEqual(i16, ply.ScalarType.i16.zigType());
    try std.testing.expectEqual(u16, ply.ScalarType.u16.zigType());
    try std.testing.expectEqual(i32, ply.ScalarType.i32.zigType());
    try std.testing.expectEqual(u32, ply.ScalarType.u32.zigType());
    try std.testing.expectEqual(f32, ply.ScalarType.f32.zigType());
    try std.testing.expectEqual(f64, ply.ScalarType.f64.zigType());
}

test "integer zigTypes" {
    try std.testing.expectEqual(i8, ply.IntegerType.i8.zigType());
    try std.testing.expectEqual(u32, ply.IntegerType.u32.zigType());
    try std.testing.expect(ply.IntegerType.i8.isSigned());
    try std.testing.expect(!ply.IntegerType.u8.isSigned());
}
