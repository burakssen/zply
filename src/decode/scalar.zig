//! Primitive integer and IEEE-754 float decoding from byte slices.
//!
//! One generic function decodes any Zig scalar type (`i8`..`u32`, `f32`,
//! `f64`) from a possibly-unaligned prefix of a byte slice, honoring an
//! explicit byte order. It is the bottom layer of the decoder: it knows
//! widths and byte order, nothing about PLY records, schemas, or I/O.
//!
//! Design points:
//!
//! * **No alignment assumptions.** Bytes are copied through a fixed-size
//!   stack buffer before `std.mem.readInt`, so a 4-byte float beginning
//!   at an odd offset (PLY records are packed) decodes correctly.
//! * **Bounded input.** The slice may be longer than one value; only the
//!   required prefix is read. An insufficient prefix is a controlled
//!   error, never an out-of-bounds read.
//! * **Floats preserve bits.** Decoding reads the integer bit pattern in
//!   the declared byte order and reinterprets it with `@bitCast` — never
//!   `@floatFromInt`. NaN payloads, infinities, subnormals, and negative
//!   zero pass through exactly.
//! * **Allocation-free.** No allocator parameter exists at this layer.
//!
//! Endianness handling for 1-byte types is delegated to `std.mem.readInt`
//! (which is a no-op for byte-sized integers); callers do not need to
//! special-case `char`/`uchar`.

const std = @import("std");

/// Errors of the primitive decoders.
pub const ScalarError = error{
    /// The slice holds fewer bytes than the scalar type's width.
    InsufficientBytes,
};

/// Decodes one scalar of compile-time-known type `T` from the beginning
/// of `bytes`, using `endian` byte order.
///
/// `T` must be one of the integer or float primitives the canonical PLY
/// 1.0 types decode to: `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `f32`,
/// `f64`. Wider integers decode naturally if ever needed; nothing here
/// is PLY-specific.
pub fn decodeScalar(comptime T: type, endian: std.builtin.Endian, bytes: []const u8) ScalarError!T {
    const width = @sizeOf(T);
    if (bytes.len < width) return error.InsufficientBytes;

    // Copy the exact prefix into a fixed-size array so `readInt` gets its
    // `*const [width]u8` operand. This also makes the decode safe for
    // arbitrary (unaligned) byte offsets.
    var buffer: [width]u8 = undefined;
    @memcpy(&buffer, bytes[0..width]);

    switch (@typeInfo(T)) {
        .float => {
            // Reinterpret the raw bits in the declared byte order. This
            // must be `@bitCast` of an integer read, never `@floatFromInt`.
            const raw = std.mem.readInt(Bits(T), &buffer, endian);
            return @bitCast(raw);
        },
        .int => return std.mem.readInt(T, &buffer, endian),
        else => @compileError("decodeScalar: unsupported type " ++ @typeName(T)),
    }
}

/// The unsigned integer type whose bit pattern is `T`'s memory layout.
pub fn Bits(comptime T: type) type {
    return @Int(.unsigned, @bitSizeOf(T));
}
