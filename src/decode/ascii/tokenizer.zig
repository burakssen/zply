//! Allocation-free scanning of one strict ASCII PLY record.
const std = @import("std");

pub const Tokenizer = struct {
    input: []const u8,
    position: usize = 0,
    max_token_bytes: usize,

    pub fn init(input: []const u8, max_token_bytes: usize) Tokenizer {
        return .{ .input = input, .max_token_bytes = max_token_bytes };
    }

    fn whitespace(b: u8) bool { return b == ' ' or b == '\t'; }

    /// Byte position of the next token (or the end of the record when
    /// the next required token is missing). Never consumes input.
    pub fn nextTokenStart(self: *const Tokenizer) usize {
        var at = self.position;
        while (at < self.input.len and whitespace(self.input[at])) at += 1;
        return at;
    }

    pub fn next(self: *Tokenizer) error{TokenTooLong, InvalidAsciiRecord}!?[]const u8 {
        while (self.position < self.input.len and whitespace(self.input[self.position])) self.position += 1;
        if (self.position == self.input.len) return null;
        const begin = self.position;
        while (self.position < self.input.len and !whitespace(self.input[self.position])) : (self.position += 1) {
            const ch = self.input[self.position];
            if (ch < 0x21 or ch > 0x7e) return error.InvalidAsciiRecord;
            if (self.position - begin >= self.max_token_bytes) return error.TokenTooLong;
        }
        return self.input[begin..self.position];
    }

    pub fn hasRemaining(self: *Tokenizer) bool {
        var cursor = self.position;
        while (cursor < self.input.len and whitespace(self.input[cursor])) cursor += 1;
        return cursor != self.input.len;
    }
};

test "tokenizer recognizes exact token boundaries and rejects control bytes" {
    var t = Tokenizer.init("  1\t -2  3.25  ", 16);
    try std.testing.expectEqualStrings("1", (try t.next()).?);
    try std.testing.expectEqualStrings("-2", (try t.next()).?);
    try std.testing.expectEqualStrings("3.25", (try t.next()).?);
    try std.testing.expect((try t.next()) == null);
    var bad = Tokenizer.init("1\x00", 16);
    try std.testing.expectError(error.InvalidAsciiRecord, bad.next());
    var long = Tokenizer.init("12345", 4);
    try std.testing.expectError(error.TokenTooLong, long.next());
}
