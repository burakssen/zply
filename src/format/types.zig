//! PLY encoding model, format version representation, and the scalar type
//! system.
//!
//! This module is a pure data model: it performs no I/O, no decoding, and no
//! allocation. Byte-level interpretation of these types happens in later
//! phases; here we only decide *what the format can express*.
//!
//! Design notes:
//! * `Encoding` is an enum, not a string. The Phase 2 header parser maps the
//!   exact `format` header token to an `Encoding` value via
//!   `Encoding.fromFormatName`.
//! * Endianness is irrelevant for ASCII data, so `ascii` is never treated as
//!   little- or big-endian; its byte order is `.none`.
//! * The supported-version policy (PLY 1.0 only) lives in header validation
//!   (`Header.isSupportedVersion`), not in the `Version` storage type, so
//!   future versions can be represented without changing this structure.

const std = @import("std");

/// The three standard PLY 1.0 encodings.
pub const Encoding = enum {
    ascii,
    binary_little_endian,
    binary_big_endian,

    /// Byte order of a binary encoding. ASCII is textual and has none.
    pub const ByteOrder = enum { none, little, big };

    /// Whether records are byte-encoded (as opposed to text).
    pub fn isBinary(encoding: Encoding) bool {
        return encoding != .ascii;
    }

    /// Byte order when the encoding is binary; `.none` for ASCII.
    pub fn byteOrder(encoding: Encoding) ByteOrder {
        return switch (encoding) {
            .ascii => .none,
            .binary_little_endian => .little,
            .binary_big_endian => .big,
        };
    }

    /// Maps the exact canonical `format` token from a PLY header to its
    /// encoding. Matching is case-sensitive: `format ascii 1.0`,
    /// `format binary_little_endian 1.0`, `format binary_big_endian 1.0`.
    /// Any other name (including differently cased spellings) is a validation
    /// failure; strict compatibility with nonstandard names is not provided.
    pub fn fromFormatName(name: []const u8) error{UnknownFormatName}!Encoding {
        const info = @typeInfo(Encoding).@"enum";
        inline for (info.field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                return @field(Encoding, field_name);
            }
        }
        return error.UnknownFormatName;
    }

    /// Canonical header token for this encoding, exactly as it must appear
    /// in a `format` line.
    pub fn formatName(encoding: Encoding) []const u8 {
        return @tagName(encoding);
    }
};

/// A PLY format version such as 1.0. Purely representational: whether a
/// version is accepted is a header-validation policy decision, kept out of
/// this storage type so future versions do not require a structural change.
pub const Version = struct {
    major: u16,
    minor: u16,
};

/// Every canonical PLY 1.0 scalar type.
///
/// `i64`, `u64`, and `f16` are deliberately absent: they are not canonical
/// PLY 1.0 types. Nonstandard extensions, if ever supported, will be added
/// through an explicit compatibility policy rather than by widening this
/// enum silently.
pub const ScalarType = enum {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    f32,
    f64,

    /// Width of the widest canonical scalar, in bytes.
    pub const max_width: usize = 8;

    /// Byte width of a single value in either binary encoding. PLY binary
    /// records are packed without padding or alignment, so this is exact.
    pub fn byteWidth(scalar: ScalarType) usize {
        return switch (scalar) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64 => 8,
        };
    }

    /// Whether the scalar is a fixed-width integer (`f32`/`f64` are not).
    pub fn isInteger(scalar: ScalarType) bool {
        return switch (scalar) {
            .i8, .u8, .i16, .u16, .i32, .u32 => true,
            .f32, .f64 => false,
        };
    }

    /// Whether the scalar is an IEEE-754 floating-point type.
    pub fn isFloating(scalar: ScalarType) bool {
        return switch (scalar) {
            .f32, .f64 => true,
            else => false,
        };
    }

    /// Whether the scalar is a signed *integer* type. Unsigned integers and
    /// floats report `false`; sign handling for floats is part of decoding,
    /// not of this classification.
    pub fn isSigned(scalar: ScalarType) bool {
        return switch (scalar) {
            .i8, .i16, .i32 => true,
            .u8, .u16, .u32, .f32, .f64 => false,
        };
    }

    /// Canonical PLY 1.0 name, as it may appear in a header `property` line.
    ///
    ///   i8 -> "char"    u8 -> "uchar"   i16 -> "short"   u16 -> "ushort"
    ///   i32 -> "int"    u32 -> "uint"   f32 -> "float"   f64 -> "double"
    pub fn name(scalar: ScalarType) []const u8 {
        return switch (scalar) {
            .i8 => "char",
            .u8 => "uchar",
            .i16 => "short",
            .u16 => "ushort",
            .i32 => "int",
            .u32 => "uint",
            .f32 => "float",
            .f64 => "double",
        };
    }

    /// Exact, case-sensitive lookup of a PLY scalar type name.
    ///
    /// Accepts the eight canonical names plus the standard PLY integer
    /// aliases: `int8`/`uint8`/`int16`/`uint16`/`int32`/`uint32`. All are
    /// defined by the PLY specification, so they are strict-mode names, not
    /// compatibility extensions. `Float` or `FLOAT` are rejected; case
    /// tolerance belongs to a documented compatibility mode (see
    /// `fromNameCompatible`).
    pub fn fromName(ply_name: []const u8) error{UnknownScalarType}!ScalarType {
        const table = comptime nameTable();
        inline for (table) |entry| {
            if (std.mem.eql(u8, ply_name, entry.ply_name)) return entry.scalar;
        }
        return error.UnknownScalarType;
    }

    /// Case-insensitive lookup, reserved for the future non-strict
    /// (`strict = false`) compatibility mode. The accepted name set is
    /// identical to `fromName`; only case sensitivity differs.
    pub fn fromNameCompatible(ply_name: []const u8) error{UnknownScalarType}!ScalarType {
        const table = comptime nameTable();
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(ply_name, entry.ply_name)) return entry.scalar;
        }
        return error.UnknownScalarType;
    }

    /// The Zig type a binary value of this scalar decodes to (after any byte
    /// order handling, which is a Phase 3 concern).
    pub fn zigType(scalar: ScalarType) type {
        return switch (scalar) {
            .i8 => i8,
            .u8 => u8,
            .i16 => i16,
            .u16 => u16,
            .i32 => i32,
            .u32 => u32,
            .f32 => f32,
            .f64 => f64,
        };
    }

    /// The corresponding `IntegerType`. Floating types are rejected because a
    /// list count must be an integer; making that unrepresentable at the type
    /// level is the whole point of `IntegerType`.
    pub fn toIntegerType(scalar: ScalarType) error{NotAnIntegerType}!IntegerType {
        return switch (scalar) {
            .i8 => .i8,
            .u8 => .u8,
            .i16 => .i16,
            .u16 => .u16,
            .i32 => .i32,
            .u32 => .u32,
            .f32, .f64 => error.NotAnIntegerType,
        };
    }

    const NameEntry = struct { ply_name: []const u8, scalar: ScalarType };

    fn nameTable() [14]NameEntry {
        return .{
            .{ .ply_name = "char", .scalar = .i8 },
            .{ .ply_name = "int8", .scalar = .i8 },
            .{ .ply_name = "uchar", .scalar = .u8 },
            .{ .ply_name = "uint8", .scalar = .u8 },
            .{ .ply_name = "short", .scalar = .i16 },
            .{ .ply_name = "int16", .scalar = .i16 },
            .{ .ply_name = "ushort", .scalar = .u16 },
            .{ .ply_name = "uint16", .scalar = .u16 },
            .{ .ply_name = "int", .scalar = .i32 },
            .{ .ply_name = "int32", .scalar = .i32 },
            .{ .ply_name = "uint", .scalar = .u32 },
            .{ .ply_name = "uint32", .scalar = .u32 },
            .{ .ply_name = "float", .scalar = .f32 },
            .{ .ply_name = "double", .scalar = .f64 },
        };
    }
};

/// Integer-only subset of `ScalarType`, used where the format requires an
/// integer: a list property's count type. A validated list property can
/// therefore never declare `float` as its count type — the invalid state is
/// unrepresentable.
pub const IntegerType = enum {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,

    /// Numeric ranges each integer type must satisfy when a value is decoded.
    /// Range *checking* happens during decoding in later phases; documented
    /// here so the requirements are visible in the type system:
    ///
    ///   i8:  [-128, 127]                 u8:  [0, 255]
    ///   i16: [-32768, 32767]             u16: [0, 65535]
    ///   i32: [-2147483648, 2147483647]   u32: [0, 4294967295]
    ///
    /// A list count read from a signed or negative value is validated there
    /// (a negative count is an error, not a wraparound).
    /// The equivalent `ScalarType`.
    pub fn scalar(integer: IntegerType) ScalarType {
        return switch (integer) {
            .i8 => .i8,
            .u8 => .u8,
            .i16 => .i16,
            .u16 => .u16,
            .i32 => .i32,
            .u32 => .u32,
        };
    }

    /// Byte width in either binary encoding.
    pub fn byteWidth(integer: IntegerType) usize {
        return integer.scalar().byteWidth();
    }

    /// Whether the integer is signed.
    pub fn isSigned(integer: IntegerType) bool {
        return integer.scalar().isSigned();
    }

    /// The Zig type this integer decodes to.
    pub fn zigType(integer: IntegerType) type {
        return integer.scalar().zigType();
    }

    /// Narrows a `ScalarType` to `IntegerType`, rejecting floating types.
    pub fn fromScalar(scalar_value: ScalarType) error{NotAnIntegerType}!IntegerType {
        return scalar_value.toIntegerType();
    }
};

comptime {
    // Byte widths must match the Zig primitive types they decode to.
    const scalar_info = @typeInfo(ScalarType).@"enum";
    for (scalar_info.field_names, scalar_info.field_values) |field_name, field_value| {
        const scalar: ScalarType = @fromBackingInt(field_value);
        if (scalar.byteWidth() != @sizeOf(scalar.zigType())) {
            @compileError("scalar width mismatch for " ++ field_name);
        }
    }
    // Every IntegerType maps to a ScalarType of the same width.
    const integer_info = @typeInfo(IntegerType).@"enum";
    for (integer_info.field_names, integer_info.field_values) |field_name, field_value| {
        const integer: IntegerType = @fromBackingInt(field_value);
        const scalar = integer.scalar();
        if (scalar.byteWidth() != integer.byteWidth()) {
            @compileError("integer/scalar width mismatch for " ++ field_name);
        }
    }
}
