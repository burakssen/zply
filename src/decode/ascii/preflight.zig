//! Allocation-free structural preflight for independently decodable ASCII
//! chunks. Scalar numerics and list item numerics are decoded only by workers.
const std = @import("std");
const property_mod = @import("../../format/property.zig");
const tokenizer = @import("tokenizer.zig");
const number = @import("number.zig");
const record = @import("record.zig");

pub const Failure = struct {
    record_index: usize = 0,
    property_index: ?usize = null,
    token_offset: ?usize = null,
};

pub const Error = record.DecodeError || error{ SizeOverflow, InvalidLayout };

pub fn stripLineEnding(raw: []const u8) Error![]const u8 {
    if (raw.len == 0 or raw[raw.len - 1] != '\n') return error.InvalidAsciiRecord;
    const n = if (raw.len >= 2 and raw[raw.len - 2] == '\r') raw.len - 2 else raw.len - 1;
    return raw[0..n];
}

/// `list_totals` has one entry per property, zero for scalar properties.
/// Returns exact decoded payload bytes (excluding pool descriptors).
pub fn scan(
    props: []const property_mod.Property,
    bytes: []const u8,
    offsets: []const usize,
    max_token_bytes: usize,
    max_list_items: usize,
    list_totals: []usize,
    failure: *Failure,
) Error!usize {
    if (props.len != list_totals.len or offsets.len == 0 or offsets[0] != 0 or offsets[offsets.len - 1] != bytes.len) return error.InvalidLayout;
    @memset(list_totals, 0);
    var total_bytes: usize = 0;
    for (0..offsets.len - 1) |r| {
        failure.* = .{ .record_index = r };
        const start = offsets[r];
        const end = offsets[r + 1];
        if (start >= end or end > bytes.len) return error.InvalidAsciiRecord;
        const line = try stripLineEnding(bytes[start..end]);
        var t = tokenizer.Tokenizer.init(line, max_token_bytes);
        for (props, 0..) |prop, pi| {
            failure.property_index = pi;
            failure.token_offset = t.nextTokenStart();
            switch (prop.kind) {
                .scalar => |scalar| {
                    _ = (try t.next()) orelse return error.MissingValue;
                    total_bytes = std.math.add(usize, total_bytes, scalar.byteWidth()) catch return error.SizeOverflow;
                },
                .list => |li| {
                    const count_token = (try t.next()) orelse return error.MissingValue;
                    const n = try number.listCount(li.count_type, count_token);
                    if (n > max_list_items) return error.ListTooLarge;
                    list_totals[pi] = std.math.add(usize, list_totals[pi], n) catch return error.SizeOverflow;
                    total_bytes = std.math.add(usize, total_bytes, std.math.mul(usize, n, li.item_type.byteWidth()) catch return error.SizeOverflow) catch return error.SizeOverflow;
                    for (0..n) |_| {
                        failure.token_offset = t.nextTokenStart();
                        _ = (try t.next()) orelse return error.MissingValue;
                    }
                },
            }
        }
        failure.property_index = null;
        failure.token_offset = t.nextTokenStart();
        if (t.hasRemaining()) return error.UnexpectedValue;
    }
    // Each list stores a prefix-sum of length N + 1 in addition to values.
    for (props) |prop| {
        if (prop.kind == .list) {
            const n_offsets = std.math.add(usize, offsets.len - 1, 1) catch return error.SizeOverflow;
            total_bytes = std.math.add(usize, total_bytes, std.math.mul(usize, n_offsets, @sizeOf(usize)) catch return error.SizeOverflow) catch return error.SizeOverflow;
        }
    }
    return total_bytes;
}

test "list structural preflight accounts exact variable columns" {
    const props = [_]property_mod.Property{
        property_mod.Property.scalar("a", .f32),
        property_mod.Property.list("b", .u8, .i32),
    };
    const bytes = "0.5 3 1 2 3\n1.5 0\n";
    const offsets = [_]usize{ 0, 12, 18 };
    var totals: [props.len]usize = undefined;
    var failure: Failure = .{};
    const size = try scan(&props, bytes, &offsets, 32, 255, &totals, &failure);
    try std.testing.expectEqual(@as(usize, 44), size);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, &totals);
}

test "preflight distinguishes missing items, extra data, and negative counts" {
    const props = [_]property_mod.Property{
        property_mod.Property.scalar("before", .f32),
        property_mod.Property.list("values", .i16, .f64),
        property_mod.Property.scalar("after", .i32),
    };
    var totals: [props.len]usize = undefined;
    var failure: Failure = .{};
    const missing = "1.0 3 9.5 7\n";
    try std.testing.expectError(error.MissingValue, scan(&props, missing, &.{ 0, missing.len }, 64, 100, &totals, &failure));
    try std.testing.expectEqual(@as(?usize, 1), failure.property_index);
    const negative = "1.0 -1 7\n";
    try std.testing.expectError(error.NegativeListCount, scan(&props, negative, &.{ 0, negative.len }, 64, 100, &totals, &failure));
    try std.testing.expectEqual(@as(?usize, 1), failure.property_index);
    const extra = "1.0 0 7 8\n";
    try std.testing.expectError(error.UnexpectedValue, scan(&props, extra, &.{ 0, extra.len }, 64, 100, &totals, &failure));
    try std.testing.expectEqual(@as(?usize, null), failure.property_index);
}
