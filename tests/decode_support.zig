//! Shared support for the decode test suites: an independent reference
//! decoder (Task 3.15) and header-driven layout fixtures.
//!
//! The reference decoder is intentionally naive — byte-at-a-time explicit
//! shifts, no `std.mem.readInt`, no shared code with the production path —
//! so randomized differential tests compare genuinely different
//! implementations. It is slow and reviewable by design; it is never
//! imported by production code.
//!
//! All decode test files use the `zply_internals` universe exclusively.

const std = @import("std");
const internals = @import("zply_internals");

pub const types = internals.types;
pub const decode = internals.decode;
pub const ScalarValue = decode.ScalarValue;

// ---------------------------------------------------------------------------
// Independent reference decoder
// ---------------------------------------------------------------------------

/// Byte-at-a-time reference decode of one scalar of type `T`.
///
/// Accumulates an unsigned integer of `T`'s width from explicit shifts,
/// then reinterprets: signed integers via `@bitCast` of the unsigned
/// accumulation, floats via `@bitCast` of the same-width unsigned bits.
pub fn refDecodeScalar(comptime T: type, endian: std.builtin.Endian, bytes: []const u8) error{InsufficientBytes}!T {
    const width = @sizeOf(T);
    if (bytes.len < width) return error.InsufficientBytes;

    const unsigned_t = @Int(.unsigned, @bitSizeOf(T));
    var raw: unsigned_t = 0;
    for (0..width) |i| {
        const shift: std.math.Log2Int(unsigned_t) = switch (endian) {
            .little => @intCast(i * 8),
            .big => @intCast((width - 1 - i) * 8),
        };
        raw |= @as(unsigned_t, bytes[i]) << shift;
    }
    return @bitCast(raw);
}

/// Reference decode of one value by declared PLY scalar type.
pub fn refDecodeValue(
    scalar_type: types.ScalarType,
    endian: std.builtin.Endian,
    bytes: []const u8,
) error{InsufficientBytes}!ScalarValue {
    switch (scalar_type) {
        .i8 => return .{ .i8 = try refDecodeScalar(i8, endian, bytes) },
        .u8 => return .{ .u8 = try refDecodeScalar(u8, endian, bytes) },
        .i16 => return .{ .i16 = try refDecodeScalar(i16, endian, bytes) },
        .u16 => return .{ .u16 = try refDecodeScalar(u16, endian, bytes) },
        .i32 => return .{ .i32 = try refDecodeScalar(i32, endian, bytes) },
        .u32 => return .{ .u32 = try refDecodeScalar(u32, endian, bytes) },
        .f32 => return .{ .f32 = try refDecodeScalar(f32, endian, bytes) },
        .f64 => return .{ .f64 = try refDecodeScalar(f64, endian, bytes) },
    }
}

// ---------------------------------------------------------------------------
// Header-driven layout fixtures
// ---------------------------------------------------------------------------

/// Parses `header_text` and returns the owned `HeaderStorage` (callers
/// must `deinit`); the compiled layouts are `storage.layouts`.
pub fn parseHeader(header_text: []const u8) !internals.header_parser.HeaderStorage {
    var reader: std.Io.Reader = .fixed(header_text);
    return internals.header_parser.parseHeader(std.testing.allocator, &reader, .{});
}

/// Compiles and validates a `FixedLayout` for element `element_index` of
/// a parsed header in the given PLY encoding.
pub fn fixedLayout(
    storage: *const internals.header_parser.HeaderStorage,
    element_index: usize,
    encoding: types.Encoding,
) !decode.FixedLayout {
    return decode.FixedLayout.initForEncoding(&storage.layouts[element_index], encoding);
}

/// Serializes one record's values into `out` (record-major, packed in the
/// given byte order) using the reference decoder's conventions. Values
/// are given as raw bit patterns of their declared types.
pub fn serializeValues(
    fixed: decode.FixedLayout,
    patterns: []const u64,
    out: []u8,
) void {
    var cursor: usize = 0;
    for (fixed.element.properties, 0..) |property, i| {
        const width = property.fixed_width.?;
        const pattern = patterns[i];
        const bytes = out[cursor..][0..width];
        cursor += width;
        for (0..width) |byte_index| {
            const shift: u6 = switch (fixed.endian) {
                .little => @intCast(byte_index * 8),
                .big => @intCast((width - 1 - byte_index) * 8),
            };
            bytes[byte_index] = @truncate(pattern >> shift);
        }
    }
}
