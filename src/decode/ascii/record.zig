//! Schema-aware, allocation-free record validation, reusable in Phase 9.
const std = @import("std");
const property = @import("../../format/property.zig");
const tokenizer = @import("tokenizer.zig");
const number = @import("number.zig");

pub const DecodeError = number.NumberError || error{
    MissingValue, UnexpectedValue, TokenTooLong, InvalidAsciiRecord,
    NegativeListCount, InvalidListCount, ListTooLarge,
};

pub fn validate(props: []const property.Property, line: []const u8, token_limit: usize, list_limit: usize) DecodeError!void {
    return validateWithContext(props, line, token_limit, list_limit, null);
}

pub fn validateWithContext(props: []const property.Property, line: []const u8, token_limit: usize, list_limit: usize, failed_property: ?*?usize) DecodeError!void {
    return validateWithOffsets(props, line, token_limit, list_limit, failed_property, null);
}

/// Returns precise byte positions within `line` for failed numeric tokens,
/// missing tokens, extra tokens, and token-size violations. The offset is
/// relative to the beginning of this complete record, not the PLY header.
pub fn validateWithOffsets(
    props: []const property.Property,
    line: []const u8,
    token_limit: usize,
    list_limit: usize,
    failed_property: ?*?usize,
    failed_token_offset: ?*?usize,
) DecodeError!void {
    var t = tokenizer.Tokenizer.init(line, token_limit);
    for (props, 0..) |prop, index| {
        if (failed_property) |out| out.* = index;
        switch (prop.kind) {
        .scalar => |type_tag| {
            if (failed_token_offset) |out| out.* = t.nextTokenStart();
            const token = (try t.next()) orelse return error.MissingValue;
            _ = try number.scalar(type_tag, token);
        },
        .list => |li| {
            if (failed_token_offset) |out| out.* = t.nextTokenStart();
            const count_token = (try t.next()) orelse return error.MissingValue;
            const count = try number.listCount(li.count_type, count_token);
            if (count > list_limit) return error.ListTooLarge;
            for (0..count) |_| {
                if (failed_token_offset) |out| out.* = t.nextTokenStart();
                const token = (try t.next()) orelse return error.MissingValue;
                _ = try number.scalar(li.item_type, token);
            }
        },
        }
    }
    if (failed_property) |out| out.* = null;
    if (t.hasRemaining()) {
        if (failed_token_offset) |out| out.* = t.nextTokenStart();
        return error.UnexpectedValue;
    }
    if (failed_token_offset) |out| out.* = null;
}
