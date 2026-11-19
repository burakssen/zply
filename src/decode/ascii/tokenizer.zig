//! Allocation-free scanning of one strict ASCII PLY record.
//!
//! Phase 12 M10: whitespace is skipped once per token. Callers commonly ask
//! for the next token's byte offset (for diagnostics) and then request the
//! token itself; the cached boundary makes those two operations a single
//! scan without changing the public behavior of the tokenizer.
const std = @import("std");

pub const Tokenizer = struct {
    input: []const u8,
    position: usize = 0,
    max_token_bytes: usize,
    cached_start: usize = 0,
    has_cached_start: bool = false,

    pub fn init(input: []const u8, max_token_bytes: usize) Tokenizer {
        return .{ .input = input, .max_token_bytes = max_token_bytes };
    }

    fn whitespace(b: u8) bool {
        return b == ' ' or b == '\t';
    }

    fn skipWhitespace(self: *const Tokenizer, from: usize) usize {
        var at = from;
        while (at < self.input.len and whitespace(self.input[at])) at += 1;
        return at;
    }

    /// Byte position of the next token (or the end of the record when
    /// the next required token is missing). Never consumes input. The
    /// result is cached until `next()` or `hasRemaining()` consumes it.
    pub fn nextTokenStart(self: *Tokenizer) usize {
        if (!self.has_cached_start) {
            self.cached_start = self.skipWhitespace(self.position);
            self.has_cached_start = true;
        }
        return self.cached_start;
    }

    pub fn next(self: *Tokenizer) error{ TokenTooLong, InvalidAsciiRecord }!?[]const u8 {
        const begin = self.nextTokenStart();
        self.has_cached_start = false;
        if (begin == self.input.len) {
            self.position = begin;
            return null;
        }
        var at = begin;
        while (at < self.input.len and !whitespace(self.input[at])) : (at += 1) {
            const ch = self.input[at];
            if (ch < 0x21 or ch > 0x7e) return error.InvalidAsciiRecord;
            if (at - begin >= self.max_token_bytes) return error.TokenTooLong;
        }
        self.position = at;
        return self.input[begin..at];
    }

    pub fn hasRemaining(self: *Tokenizer) bool {
        return self.nextTokenStart() != self.input.len;
    }
};

test "tokenizer recognizes exact token boundaries and rejects control bytes" {
    var t = Tokenizer.init("  1\t -2  3.25  ", 16);
    try std.testing.expectEqual(@as(usize, 2), t.nextTokenStart());
    try std.testing.expectEqualStrings("1", (try t.next()).?);
    try std.testing.expectEqual(@as(usize, 5), t.nextTokenStart());
    try std.testing.expectEqualStrings("-2", (try t.next()).?);
    try std.testing.expectEqualStrings("3.25", (try t.next()).?);
    try std.testing.expect((try t.next()) == null);
    try std.testing.expect(!t.hasRemaining());

    var bad = Tokenizer.init("1\x00", 16);
    try std.testing.expectError(error.InvalidAsciiRecord, bad.next());
    var long = Tokenizer.init("12345", 4);
    try std.testing.expectError(error.TokenTooLong, long.next());

    // The diagnostic offset must survive a tokenizer error.
    var long_offset = Tokenizer.init("  12345", 4);
    try std.testing.expectEqual(@as(usize, 2), long_offset.nextTokenStart());
    try std.testing.expectError(error.TokenTooLong, long_offset.next());
}
