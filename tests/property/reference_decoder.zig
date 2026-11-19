//! Small, independent PLY 1.0 oracle for Phase 11 M10 test documents.
//!
//! This intentionally imports neither zply nor the M9 generator: it parses
//! header lines, decimal tokens, list prefixes, and endian-aware binary bytes
//! directly. It is bounded to the M9 generator's small schemas and records.
//! A failure in this oracle is a test-harness failure, not a parser error.
const std = @import("std");

pub const max_elements = 3;
pub const max_properties = 8;
pub const max_records = 6;
pub const max_items = 4;

pub const Encoding = enum { ascii, binary_little_endian, binary_big_endian };
pub const Scalar = enum {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    f32,
    f64,

    fn width(self: Scalar) usize {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64 => 8,
        };
    }

    fn fromPlyName(name: []const u8) !Scalar {
        if (std.mem.eql(u8, name, "char")) return .i8;
        if (std.mem.eql(u8, name, "uchar")) return .u8;
        if (std.mem.eql(u8, name, "short")) return .i16;
        if (std.mem.eql(u8, name, "ushort")) return .u16;
        if (std.mem.eql(u8, name, "int")) return .i32;
        if (std.mem.eql(u8, name, "uint")) return .u32;
        if (std.mem.eql(u8, name, "float")) return .f32;
        if (std.mem.eql(u8, name, "double")) return .f64;
        return error.ReferenceInvalidScalar;
    }

    fn integer(self: Scalar) bool {
        return switch (self) {
            .f32, .f64 => false,
            else => true,
        };
    }
};

pub const Property = struct {
    name: []const u8,
    ty: Scalar,
    count_type: ?Scalar = null,
};
pub const Element = struct {
    name: []const u8 = "",
    count: usize = 0,
    property_count: usize = 0,
    properties: [max_properties]Property = undefined,
};
pub const Cell = struct {
    len: usize = 0,
    bits: [max_items]u64 = undefined,
};
pub const Result = struct {
    encoding: Encoding,
    element_count: usize = 0,
    elements: [max_elements]Element = undefined,
    cells: [max_elements][max_records][max_properties]Cell = undefined,
    /// Logical end of the declared PLY body; any following bytes are ignored.
    body_end: usize = 0,
};

const Cursor = struct {
    input: []const u8,
    at: usize = 0,

    fn line(self: *Cursor) ![]const u8 {
        if (self.at > self.input.len) return error.ReferenceTruncated;
        const relative = std.mem.indexOfScalar(u8, self.input[self.at..], '\n') orelse
            return error.ReferenceTruncated;
        const end = self.at + relative;
        const start = self.at;
        self.at = end + 1;
        const result = self.input[start..end];
        return if (std.mem.endsWith(u8, result, "\r")) result[0 .. result.len - 1] else result;
    }

    fn bytes(self: *Cursor, size: usize) ![]const u8 {
        if (size > self.input.len - self.at) return error.ReferenceTruncated;
        const part = self.input[self.at..][0..size];
        self.at += size;
        return part;
    }

    fn bits(self: *Cursor, size: usize, encoding: Encoding) !u64 {
        const part = try self.bytes(size);
        var value: u64 = 0;
        if (encoding == .binary_little_endian) {
            for (part, 0..) |byte, i| {
                value |= @as(u64, byte) << @as(u6, @intCast(i * 8));
            }
        } else {
            for (part) |byte| value = (value << 8) | byte;
        }
        return value;
    }
};

fn required(tokens: anytype) ![]const u8 {
    return tokens.next() orelse error.ReferenceInvalidHeader;
}

fn noMore(tokens: anytype) !void {
    if (tokens.next() != null) return error.ReferenceInvalidHeader;
}

fn decimalBits(ty: Scalar, token: []const u8) !u64 {
    // Parsed independently from zply's ASCII numeric lexer.
    return switch (ty) {
        .i8 => @as(u8, @bitCast(try std.fmt.parseInt(i8, token, 10))),
        .u8 => try std.fmt.parseInt(u8, token, 10),
        .i16 => @as(u16, @bitCast(try std.fmt.parseInt(i16, token, 10))),
        .u16 => try std.fmt.parseInt(u16, token, 10),
        .i32 => @as(u32, @bitCast(try std.fmt.parseInt(i32, token, 10))),
        .u32 => try std.fmt.parseInt(u32, token, 10),
        .f32 => @as(u32, @bitCast(try std.fmt.parseFloat(f32, token))),
        .f64 => @as(u64, @bitCast(try std.fmt.parseFloat(f64, token))),
    };
}

fn countFromBits(ty: Scalar, bits: u64) !usize {
    if (!ty.integer()) return error.ReferenceInvalidCount;
    const count: i64 = switch (ty) {
        .i8 => @as(i8, @bitCast(@as(u8, @truncate(bits)))),
        .u8 => @as(u8, @truncate(bits)),
        .i16 => @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .u16 => @as(u16, @truncate(bits)),
        .i32 => @as(i32, @bitCast(@as(u32, @truncate(bits)))),
        .u32 => @as(u32, @truncate(bits)),
        .f32, .f64 => unreachable,
    };
    if (count < 0) return error.ReferenceNegativeCount;
    if (count > max_items) return error.ReferenceListLimit;
    return @intCast(count);
}

pub fn decode(input: []const u8) !Result {
    var cursor: Cursor = .{ .input = input };
    if (!std.mem.eql(u8, try cursor.line(), "ply")) return error.ReferenceInvalidHeader;
    var result: Result = .{ .encoding = undefined };
    var saw_format = false;
    var current_element: ?usize = null;
    while (true) {
        const line = try cursor.line();
        if (std.mem.eql(u8, line, "end_header")) break;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = parts.next() orelse return error.ReferenceInvalidHeader;
        if (std.mem.eql(u8, keyword, "format")) {
            if (saw_format or result.element_count != 0) return error.ReferenceInvalidHeader;
            const format = try required(&parts);
            const version = try required(&parts);
            try noMore(&parts);
            if (!std.mem.eql(u8, version, "1.0")) return error.ReferenceInvalidHeader;
            if (std.mem.eql(u8, format, "ascii")) {
                result.encoding = .ascii;
            } else if (std.mem.eql(u8, format, "binary_little_endian")) {
                result.encoding = .binary_little_endian;
            } else if (std.mem.eql(u8, format, "binary_big_endian")) {
                result.encoding = .binary_big_endian;
            } else return error.ReferenceInvalidHeader;
            saw_format = true;
        } else if (std.mem.eql(u8, keyword, "element")) {
            if (!saw_format or result.element_count == max_elements) return error.ReferenceInvalidHeader;
            const name = try required(&parts);
            const count = std.fmt.parseInt(usize, try required(&parts), 10) catch
                return error.ReferenceInvalidHeader;
            try noMore(&parts);
            if (count > max_records) return error.ReferenceLimit;
            current_element = result.element_count;
            result.elements[result.element_count] = .{ .count = count, .name = name };
            result.element_count += 1;
        } else if (std.mem.eql(u8, keyword, "property")) {
            const e = current_element orelse return error.ReferenceInvalidHeader;
            const element = &result.elements[e];
            if (element.property_count == max_properties) return error.ReferenceLimit;
            const kind = try required(&parts);
            var property: Property = undefined;
            if (std.mem.eql(u8, kind, "list")) {
                const count_type = try Scalar.fromPlyName(try required(&parts));
                if (!count_type.integer()) return error.ReferenceInvalidCount;
                const item_type = try Scalar.fromPlyName(try required(&parts));
                const name = try required(&parts);
                property = .{ .name = name, .ty = item_type, .count_type = count_type };
            } else {
                const ty = try Scalar.fromPlyName(kind);
                property = .{ .name = try required(&parts), .ty = ty };
            }
            try noMore(&parts);
            element.properties[element.property_count] = property;
            element.property_count += 1;
        } else if (std.mem.eql(u8, keyword, "comment") or std.mem.eql(u8, keyword, "obj_info")) {
            continue;
        } else return error.ReferenceInvalidHeader;
    }
    if (!saw_format) return error.ReferenceInvalidHeader;

    for (result.elements[0..result.element_count], 0..) |element, e| {
        for (0..element.count) |r| {
            if (result.encoding == .ascii) {
                const line = try cursor.line();
                var tokens = std.mem.tokenizeAny(u8, line, " \t");
                for (element.properties[0..element.property_count], 0..) |property, p| {
                    var cell: Cell = .{};
                    if (property.count_type) |ct| {
                        cell.len = try countFromBits(ct, try decimalBits(ct, tokens.next() orelse
                            return error.ReferenceMissingValue));
                    } else cell.len = 1;
                    for (0..cell.len) |j| {
                        cell.bits[j] = try decimalBits(property.ty, tokens.next() orelse
                            return error.ReferenceMissingValue);
                    }
                    result.cells[e][r][p] = cell;
                }
                if (tokens.next() != null) return error.ReferenceExtraValue;
            } else {
                for (element.properties[0..element.property_count], 0..) |property, p| {
                    var cell: Cell = .{};
                    if (property.count_type) |ct| {
                        cell.len = try countFromBits(ct, try cursor.bits(ct.width(), result.encoding));
                    } else cell.len = 1;
                    for (0..cell.len) |j| cell.bits[j] = try cursor.bits(property.ty.width(), result.encoding);
                    result.cells[e][r][p] = cell;
                }
            }
        }
    }
    result.body_end = cursor.at;
    return result;
}
