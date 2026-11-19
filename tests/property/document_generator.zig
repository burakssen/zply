//! Phase 11 M9: an independent, bounded, deterministic PLY 1.0 generator.
//!
//! This module does not import zply, its schema compiler, its record scanners,
//! or its decoders. A reference document is constructed first, then serialized
//! into ASCII, binary little-endian, or binary big-endian bytes.
const std = @import("std");

pub const max_elements = 3;
pub const max_properties = 8;
pub const max_records = 6;
pub const max_list_items = 4;

pub const Encoding = enum { ascii, binary_little_endian, binary_big_endian };
pub const Scalar = enum {
    i8, u8, i16, u16, i32, u32, f32, f64,

    pub fn name(self: Scalar) []const u8 {
        return switch (self) {
            .i8 => "char", .u8 => "uchar", .i16 => "short", .u16 => "ushort",
            .i32 => "int", .u32 => "uint", .f32 => "float", .f64 => "double",
        };
    }
    pub fn width(self: Scalar) usize {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64 => 8,
        };
    }
};

pub const Property = struct {
    ty: Scalar,
    is_list: bool = false,
    count_type: Scalar = .u8,
};
pub const Element = struct {
    count: usize = 0,
    property_count: usize = 0,
    properties: [max_properties]Property = undefined,

    fn scalar(self: *Element, ty: Scalar) void {
        std.debug.assert(self.property_count < max_properties);
        self.properties[self.property_count] = .{ .ty = ty };
        self.property_count += 1;
    }
    fn list(self: *Element, count_type: Scalar, item_type: Scalar) void {
        std.debug.assert(self.property_count < max_properties);
        self.properties[self.property_count] = .{
            .ty = item_type, .is_list = true, .count_type = count_type,
        };
        self.property_count += 1;
    }
};

/// For scalars, len=1; for lists, len is the count prefix. Each stored value
/// is the raw unsigned bit pattern of the declared scalar width, not a value
/// recovered by parsing the generated PLY. The reference is encoding-neutral.
pub const Cell = struct {
    len: usize = 0,
    bits: [max_list_items]u64 = undefined,
};

pub const Document = struct {
    bytes: [32 * 1024]u8 = undefined,
    len: usize = 0,
    body_start: usize = 0,
    encoding: Encoding,
    seed: u64,
    element_count: usize = 0,
    elements: [max_elements]Element = undefined,
    cells: [max_elements][max_records][max_properties]Cell = undefined,

    pub fn source(self: *const Document) []const u8 {
        return self.bytes[0..self.len];
    }

    fn append(self: *Document, data: []const u8) !void {
        if (data.len > self.bytes.len - self.len) return error.GeneratedDocumentTooLarge;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn print(self: *Document, comptime fmt: []const u8, args: anytype) !void {
        const result = std.fmt.bufPrint(self.bytes[self.len..], fmt, args) catch
            return error.GeneratedDocumentTooLarge;
        self.len += result.len;
    }

    fn schema(self: *Document, random: std.Random) void {
        const family: u8 = @intCast(self.seed % 6);
        switch (family) {
            0 => { // All eight scalar types in declaration order.
                self.element_count = 1;
                self.elements[0] = .{ .count = 4 };
                inline for (.{ Scalar.i8, Scalar.u8, Scalar.i16, Scalar.u16, Scalar.i32, Scalar.u32, Scalar.f32, Scalar.f64 }) |ty|
                    self.elements[0].scalar(ty);
            },
            1 => { // Lists interleaved with scalars, two element schemas.
                self.element_count = 2;
                self.elements[0] = .{ .count = 6 };
                self.elements[0].scalar(.f32);
                self.elements[0].list(.u8, .i32);
                self.elements[0].scalar(.u16);
                self.elements[0].list(.u16, .f64);
                self.elements[0].scalar(.i8);
                self.elements[1] = .{ .count = 3 };
                self.elements[1].list(.i16, .u32);
                self.elements[1].scalar(.f64);
            },
            2 => { // Zero-count and zero-property elements, across formats.
                self.element_count = 3;
                self.elements[0] = .{ .count = 0 };
                self.elements[0].scalar(.u32);
                self.elements[1] = .{ .count = 3 }; // No properties.
                self.elements[2] = .{ .count = 2 };
                self.elements[2].list(.i8, .u8);
                self.elements[2].scalar(.i16);
            },
            3 => { // Multiple independent list offsets and signed counts.
                self.element_count = 2;
                self.elements[0] = .{ .count = 5 };
                self.elements[0].list(.i8, .i8);
                self.elements[0].list(.u32, .f32);
                self.elements[0].scalar(.u8);
                self.elements[0].list(.i32, .u16);
                self.elements[1] = .{ .count = 2 };
                self.elements[1].scalar(.i32);
            },
            else => { // Seeded, variable element counts, widths, and order.
                self.element_count = random.intRangeAtMost(usize, 1, max_elements);
                for (self.elements[0..self.element_count], 0..) |*elem, i| {
                    elem.* = .{ .count = random.intRangeAtMost(usize, 0, max_records) };
                    if (i == self.element_count - 1 and elem.count == 0) elem.count = 1;
                    const n = random.intRangeAtMost(usize, 0, max_properties);
                    for (0..n) |_| {
                        const ty: Scalar = @enumFromInt(random.intRangeAtMost(u8, 0, 7));
                        if (random.boolean()) {
                            const count_types = [_]Scalar{ .i8, .u8, .i16, .u16, .i32, .u32 };
                            elem.list(count_types[random.intRangeAtMost(usize, 0, count_types.len - 1)], ty);
                        } else elem.scalar(ty);
                    }
                }
            },
        }
    }

    fn randomBits(random: std.Random, ty: Scalar) u64 {
        return switch (ty) {
            .i8 => @as(u8, @bitCast(random.int(i8))),
            .u8 => random.int(u8),
            .i16 => @as(u16, @bitCast(random.int(i16))),
            .u16 => random.int(u16),
            .i32 => @as(u32, @bitCast(random.int(i32))),
            .u32 => random.int(u32),
            // Exactly representable decimal values across all three PLY
            // encodings, including negative zero and fractional values.
            .f32 => switch (random.intRangeAtMost(u8, 0, 6)) {
                0 => 0x00000000, 1 => 0x80000000, 2 => 0x3f000000,
                3 => 0xbfc00000, 4 => 0x3f800000, 5 => 0x42c80000,
                else => 0x4b800000,
            },
            .f64 => switch (random.intRangeAtMost(u8, 0, 6)) {
                0 => 0x0000000000000000, 1 => 0x8000000000000000,
                2 => 0x3fe0000000000000, 3 => 0xbff8000000000000,
                4 => 0x3ff0000000000000, 5 => 0x4059000000000000,
                else => 0x4170000000000000,
            },
        };
    }

    fn populate(self: *Document, random: std.Random) void {
        for (self.elements[0..self.element_count], 0..) |elem, e| {
            for (0..elem.count) |r| {
                for (elem.properties[0..elem.property_count], 0..) |prop, p| {
                    var cell: Cell = .{};
                    cell.len = if (prop.is_list) random.intRangeAtMost(usize, 0, max_list_items) else 1;
                    for (0..cell.len) |j| cell.bits[j] = randomBits(random, prop.ty);
                    self.cells[e][r][p] = cell;
                }
            }
        }
    }

    fn appendBits(self: *Document, bits: u64, width: usize) !void {
        const endian: std.builtin.Endian = if (self.encoding == .binary_little_endian) .little else .big;
        var raw: [8]u8 = undefined;
        for (0..width) |i| {
            const position = if (endian == .little) i else width - 1 - i;
            raw[i] = @truncate(bits >> @as(u6, @intCast(position * 8)));
        }
        try self.append(raw[0..width]);
    }

    fn scalar(self: *Document, ty: Scalar, bits: u64) !void {
        if (self.encoding != .ascii) return self.appendBits(bits, ty.width());
        switch (ty) {
            .i8 => try self.print("{d}", .{@as(i8, @bitCast(@as(u8, @truncate(bits))))}),
            .u8 => try self.print("{d}", .{@as(u8, @truncate(bits))}),
            .i16 => try self.print("{d}", .{@as(i16, @bitCast(@as(u16, @truncate(bits))))}),
            .u16 => try self.print("{d}", .{@as(u16, @truncate(bits))}),
            .i32 => try self.print("{d}", .{@as(i32, @bitCast(@as(u32, @truncate(bits))))}),
            .u32 => try self.print("{d}", .{@as(u32, @truncate(bits))}),
            .f32 => {
                if (bits == 0x80000000) return self.append("-0");
                try self.print("{d}", .{@as(f32, @bitCast(@as(u32, @truncate(bits))))});
            },
            .f64 => {
                if (bits == 0x8000000000000000) return self.append("-0");
                try self.print("{d}", .{@as(f64, @bitCast(bits))});
            },
        }
    }

    fn serialize(self: *Document) !void {
        try self.append("ply\n");
        switch (self.encoding) {
            .ascii => try self.append("format ascii 1.0\n"),
            .binary_little_endian => try self.append("format binary_little_endian 1.0\n"),
            .binary_big_endian => try self.append("format binary_big_endian 1.0\n"),
        }
        for (self.elements[0..self.element_count], 0..) |elem, e| {
            try self.print("element element_{d} {d}\n", .{ e, elem.count });
            for (elem.properties[0..elem.property_count], 0..) |prop, p| {
                if (prop.is_list) {
                    try self.print("property list {s} {s} field_{d}\n", .{
                        prop.count_type.name(), prop.ty.name(), p,
                    });
                } else {
                    try self.print("property {s} field_{d}\n", .{ prop.ty.name(), p });
                }
            }
        }
        try self.append("end_header\n");
        self.body_start = self.len;
        for (self.elements[0..self.element_count], 0..) |elem, e| {
            for (0..elem.count) |r| {
                var first = true;
                for (elem.properties[0..elem.property_count], 0..) |prop, p| {
                    const cell = self.cells[e][r][p];
                    if (self.encoding == .ascii and !first) try self.append(" ");
                    if (prop.is_list) {
                        if (self.encoding == .ascii) {
                            try self.print("{d}", .{cell.len});
                        } else try self.appendBits(cell.len, prop.count_type.width());
                        for (0..cell.len) |j| {
                            if (self.encoding == .ascii) try self.append(" ");
                            try self.scalar(prop.ty, cell.bits[j]);
                        }
                    } else try self.scalar(prop.ty, cell.bits[0]);
                    first = false;
                }
                if (self.encoding == .ascii) try self.append("\n");
            }
        }
        try self.append("TAIL"); // Must remain logically unread on success.
    }

    pub fn generate(seed: u64, encoding: Encoding) !Document {
        var result: Document = .{ .seed = seed, .encoding = encoding };
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        result.schema(random);
        result.populate(random);
        try result.serialize();
        return result;
    }
};
