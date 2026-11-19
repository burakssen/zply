//! Endian-aware decoding tests (Tasks 3.3–3.5, 3.15): byte-order
//! semantics, unaligned access, and randomized differential comparison
//! against the independent reference decoder in `decode_support.zig`.
//!
//! Uses the internals universe exclusively.

const std = @import("std");
const support = @import("decode_support.zig");

const decode = support.decode;
const types = support.types;
const ScalarValue = support.ScalarValue;

const all_scalars = [_]types.ScalarType{
    .i8, .u8, .i16, .u16, .i32, .u32, .f32, .f64,
};

// ---------------------------------------------------------------------------
// Byte-order semantics
// ---------------------------------------------------------------------------

test "the same bytes decode differently under the two declared orders" {
    // 0x12345678 serialized little-endian: 78 56 34 12.
    const le_bytes = [4]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqual(
        @as(u32, 0x12345678),
        try decode.decodeScalarAs(u32, .little, &le_bytes),
    );
    try std.testing.expectEqual(
        @as(u32, 0x78563412),
        try decode.decodeScalarAs(u32, .big, &le_bytes),
    );

    // The same value serialized big-endian decodes back identically.
    const be_bytes = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    try std.testing.expectEqual(
        @as(u32, 0x12345678),
        try decode.decodeScalarAs(u32, .big, &be_bytes),
    );
}

test "encoding dispatch reaches every scalar type through both orders" {
    // Serialize every canonical type little-endian via the reference
    // decoder conventions, then confirm the production path decodes the
    // identical bits with the matching order for both endian modes.
    var prng = std.Random.DefaultPrng.init(0x5CA1AB1E);
    const rand = prng.random();

    for (all_scalars) |scalar_type| {
        const width = scalar_type.byteWidth();
        var bytes: [8]u8 = undefined;
        for (0..width) |i| bytes[i] = rand.int(u8);

        inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
            const expected = try support.refDecodeValue(scalar_type, endian, bytes[0..width]);
            const actual = try decode.decodeScalar(scalar_type, endian, bytes[0..width]);
            try std.testing.expect(expected.bitsEqual(actual));
        }
    }
}

// ---------------------------------------------------------------------------
// Unaligned access (Task 3.5.4 / 3.14.4)
// ---------------------------------------------------------------------------

test "scalars decode identically from every unaligned offset" {
    // f32 1.0 (00 00 80 3F little-endian) prefixed with 1..7 junk bytes:
    // the four-byte value must decode identically from each position.
    const pattern = [4]u8{ 0x00, 0x00, 0x80, 0x3F };
    for (0..8) |prefix_len| {
        var buffer: [12]u8 = @splat(0xEE);
        @memcpy(buffer[prefix_len..][0..4], &pattern);
        const value = try decode.decodeScalarAs(f32, .little, buffer[prefix_len..]);
        try std.testing.expectEqual(@as(u32, 0x3F800000), @as(u32, @bitCast(value)));
    }

    // 16-, 32-, and 64-bit scalars from every offset 0..7: the value
    // (0xA5B4C3D2E7F6...) decodes identically regardless of position.
    const raw: u64 = 0xA5B4C3D2E7F61357;
    for (0..8) |prefix_len| {
        var buffer: [16]u8 = @splat(0x11);
        for (0..8) |i| buffer[prefix_len + i] = @truncate(raw >> @as(u6, @intCast(8 * i)));

        const tail = buffer[prefix_len..];
        try std.testing.expectEqual(
            @as(u16, 0x1357),
            try decode.decodeScalarAs(u16, .little, tail),
        );
        try std.testing.expectEqual(
            @as(i32, @bitCast(@as(u32, 0xE7F61357))),
            try decode.decodeScalarAs(i32, .little, tail),
        );
        try std.testing.expectEqual(raw, try decode.decodeScalarAs(u64, .little, tail));

        // And big-endian: the same little-endian-serialized bytes now
        // decode to the byte-swapped values (correct per byte order).
        try std.testing.expectEqual(
            @as(u16, 0x5713),
            try decode.decodeScalarAs(u16, .big, tail),
        );
        try std.testing.expectEqual(
            @as(u64, @byteSwap(@as(u64, raw))),
            try decode.decodeScalarAs(u64, .big, tail),
        );
    }
}

// ---------------------------------------------------------------------------
// Randomized differential tests (Task 3.15)
// ---------------------------------------------------------------------------

test "differential: production scalar decoding matches the reference decoder" {
    var prng = std.Random.DefaultPrng.init(0xDECAFBAD);
    const rand = prng.random();

    const trials_per_case = 512;
    inline for (all_scalars) |scalar_type| {
        const width = scalar_type.byteWidth();
        const T = scalar_type.zigType();
        var buffer: [8]u8 = undefined;

        var trial: usize = 0;
        while (trial < trials_per_case) : (trial += 1) {
            // Fully random bytes: every possible bit pattern is a valid
            // value of every canonical scalar type.
            for (0..width) |i| buffer[i] = rand.int(u8);

            inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
                const expected = try support.refDecodeValue(scalar_type, endian, buffer[0..width]);
                const actual = try decode.decodeScalar(scalar_type, endian, buffer[0..width]);
                try std.testing.expect(expected.bitsEqual(actual));

                // The typed primitive agrees with the generic dispatch.
                const typed = try decode.decodeScalarAs(T, endian, buffer[0..width]);
                const typed_bits: u64 = switch (scalar_type) {
                    .i8 => @as(u8, @bitCast(typed)),
                    .u8 => @as(u64, typed),
                    .i16 => @as(u16, @bitCast(typed)),
                    .u16 => @as(u64, typed),
                    .i32 => @as(u32, @bitCast(typed)),
                    .u32 => @as(u64, typed),
                    .f32 => @as(u32, @bitCast(typed)),
                    .f64 => @as(u64, @bitCast(typed)),
                };
                try std.testing.expectEqual(expected.bits(), typed_bits);
            }
        }
    }
}

test "differential: truncated inputs fail identically in both implementations" {
    var prng = std.Random.DefaultPrng.init(0x0DEFACED);
    const rand = prng.random();

    for (all_scalars) |scalar_type| {
        const width = scalar_type.byteWidth();
        var bytes: [8]u8 = undefined;
        for (0..width) |i| bytes[i] = rand.int(u8);

        var length: usize = 0;
        while (length < width) : (length += 1) {
            try std.testing.expectError(
                error.InsufficientBytes,
                decode.decodeScalar(scalar_type, .little, bytes[0..length]),
            );
            try std.testing.expectError(
                error.InsufficientBytes,
                support.refDecodeValue(scalar_type, .big, bytes[0..length]),
            );
        }
    }
}

test "differential: random fixed-width layouts and records match the reference" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xFACEB00C);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 64) : (trial += 1) {
        // Generate a random all-scalar schema with 1..8 properties.
        var header_text: std.ArrayList(u8) = .empty;
        defer header_text.deinit(allocator);

        const endian: std.builtin.Endian = if (trial % 2 == 0) .little else .big;
        const encoding: types.Encoding = if (endian == .little)
            .binary_little_endian
        else
            .binary_big_endian;

        var schema: [8]types.ScalarType = undefined;
        var schema_len: usize = 0;

        try header_text.appendSlice(allocator, "ply\nformat ");
        try header_text.appendSlice(allocator, encoding.formatName());
        try header_text.appendSlice(allocator, " 1.0\nelement vertex 8\n");
        // 8 records so the traversal loops a handful of times; record
        // size is deliberately not a power of two in most trials.
        const property_count = 1 + rand.uintLessThan(usize, 8);
        for (0..property_count) |pi| {
            const scalar_type = all_scalars[rand.uintLessThan(usize, all_scalars.len)];
            schema[pi] = scalar_type;
            schema_len = pi + 1;
            try header_text.appendSlice(allocator, "property ");
            try header_text.appendSlice(allocator, scalar_type.name());
            try header_text.appendSlice(allocator, " p");
            var num_buf: [8]u8 = undefined;
            try header_text.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}\n", .{pi}));
        }
        try header_text.appendSlice(allocator, "end_header\n");
        // Record bytes follow below.

        var storage = try support.parseHeader(header_text.items);
        defer storage.deinit();
        const fixed = try support.fixedLayout(&storage, 0, encoding);

        const record_count: u64 = 8;
        const record_size = fixed.record_size;

        // Deterministic record bytes: pattern depends on record index and
        // property position, masked to each property's declared width.
        var bytes = try allocator.alloc(u8, record_count * record_size);
        defer allocator.free(bytes);

        for (0..record_count) |ri| {
            const record = bytes[ri * record_size ..][0..record_size];
            for (fixed.element.properties, 0..) |property, pi| {
                const width = property.fixed_width.?;
                // Arbitrary bit pattern (valid for every scalar type,
                // floats included), masked to the property width.
                const pattern: u64 = (0x9E3779B97F4A7C15 ^
                    (@as(u64, ri) *% 0x100000001B3) ^ (@as(u64, pi) *% 0xD1B54A32D192ED03)) &
                    maskFor(width);
                for (0..width) |byte_index| {
                    const shift: u6 = switch (endian) {
                        .little => @intCast(byte_index * 8),
                        .big => @intCast((width - 1 - byte_index) * 8),
                    };
                    record[property.fixed_offset.? + byte_index] =
                        @truncate(pattern >> shift);
                }
            }
        }

        // Traverse with the production decoder and compare every
        // property of every record against the reference decoder.
        const Counter = struct {
            schema: []const types.ScalarType,
            endian: std.builtin.Endian,
            comparisons: usize = 0,

            fn consume(self: *@This(), _: u64, view: decode.RecordView) anyerror!void {
                const record = view.bytes;
                for (self.schema, 0..) |scalar_type, pi| {
                    const property = view.fixed.element.properties[pi];
                    const expected = try support.refDecodeValue(
                        scalar_type,
                        self.endian,
                        record[property.fixed_offset.?..],
                    );
                    const actual = try view.get(pi);
                    try std.testing.expect(expected.bitsEqual(actual));
                    self.comparisons += 1;
                }
            }
        };

        var counter = Counter{
            .schema = schema[0..schema_len],
            .endian = endian,
        };
        try decode.decodeRange(fixed, bytes, record_count, &counter, Counter.consume);
        try std.testing.expectEqual(@as(usize, 8 * schema_len), counter.comparisons);
    }
}

fn maskFor(width: usize) u64 {
    return switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        4 => 0xFFFF_FFFF,
        8 => 0xFFFF_FFFF_FFFF_FFFF,
        else => unreachable,
    };
}
