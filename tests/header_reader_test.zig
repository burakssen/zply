//! Tests for the bounded header line reader (Task 2.2): LF/CRLF handling,
//! byte accounting, size limits, EOF handling, and reader independence.
//!
//! Uses the internals module (the line reader is not part of the public
//! API) and never mixes with `zply`-module types.

const std = @import("std");
const internals = @import("zply_internals");

const HeaderLineReader = internals.header_reader.HeaderLineReader;
const Options = internals.options.Options;

/// Reads every line until EOF; returns them plus the consumed byte count.
/// Reads every line until EOF; returns duplicated lines (owned by the
/// caller) plus the consumed byte count.
fn readAll(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !struct {
    lines: std.ArrayList([]const u8),
    bytes_consumed: u64,
} {
    var reader: std.Io.Reader = .fixed(bytes);
    var line_reader = HeaderLineReader.init(&reader, allocator, options);
    defer line_reader.deinit();

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    while (try line_reader.nextLine()) |line| {
        try lines.append(allocator, try allocator.dupe(u8, line));
    }
    return .{
        .lines = lines,
        .bytes_consumed = line_reader.bytes_consumed,
    };
}

/// Frees a `readAll` result.
fn freeResult(allocator: std.mem.Allocator, result: anytype) void {
    for (result.lines.items) |line| allocator.free(line);
    result.lines.deinit(allocator);
}

test "LF lines: content, line numbers, and exact byte accounting" {
    const allocator = std.testing.allocator;
    const bytes = "ply\nformat ascii 1.0\n";

    var reader: std.Io.Reader = .fixed(bytes);
    var line_reader = HeaderLineReader.init(&reader, allocator, .{});
    defer line_reader.deinit();

    const line1 = (try line_reader.nextLine()).?;
    try std.testing.expectEqualStrings("ply", line1);
    try std.testing.expectEqual(@as(u64, 4), line_reader.bytes_consumed);
    try std.testing.expectEqual(@as(u64, 1), line_reader.line_number);

    const line2 = (try line_reader.nextLine()).?;
    try std.testing.expectEqualStrings("format ascii 1.0", line2);
    try std.testing.expectEqual(@as(u64, 21), line_reader.bytes_consumed);
    try std.testing.expectEqual(@as(u64, 2), line_reader.line_number);

    // Clean EOF at a line boundary.
    try std.testing.expectEqual(@as(?[]const u8, null), try line_reader.nextLine());
}

test "CRLF: terminator stripped, both bytes counted" {
    const allocator = std.testing.allocator;
    var result = try readAll(allocator, "ply\r\nformat ascii 1.0\r\n", .{});
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.lines.items.len);
    try std.testing.expectEqualStrings("ply", result.lines.items[0]);
    try std.testing.expectEqualStrings("format ascii 1.0", result.lines.items[1]);
    // 5 + 18: both CRLF bytes counted.
    try std.testing.expectEqual(@as(u64, 23), result.bytes_consumed);
}

test "LF and CRLF mixed in one stream" {
    const allocator = std.testing.allocator;
    var result = try readAll(allocator, "a\nb\r\nc\n", .{});
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 3), result.lines.items.len);
    try std.testing.expectEqualStrings("a", result.lines.items[0]);
    try std.testing.expectEqualStrings("b", result.lines.items[1]);
    try std.testing.expectEqualStrings("c", result.lines.items[2]);
    try std.testing.expectEqual(@as(u64, 7), result.bytes_consumed);
}

test "bare CR is rejected" {
    var reader: std.Io.Reader = .fixed("ply\rformat ascii 1.0\n");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, .{});
    defer line_reader.deinit();
    try std.testing.expectError(error.InvalidLineEnding, line_reader.nextLine());
}

test "CR CR LF is rejected (invalid carriage return remaining)" {
    var reader: std.Io.Reader = .fixed("ply\r\r\n");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, .{});
    defer line_reader.deinit();
    try std.testing.expectError(error.InvalidLineEnding, line_reader.nextLine());
}

test "CR at end of stream is an unterminated line" {
    var reader: std.Io.Reader = .fixed("ply\r");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, .{});
    defer line_reader.deinit();
    try std.testing.expectError(error.UnexpectedEndOfHeader, line_reader.nextLine());
}

test "empty lines are returned as empty content" {
    const allocator = std.testing.allocator;
    var result = try readAll(allocator, "\n\nx\n", .{});
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 3), result.lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.lines.items[0].len);
    try std.testing.expectEqual(@as(usize, 0), result.lines.items[1].len);
    try std.testing.expectEqualStrings("x", result.lines.items[2]);
    try std.testing.expectEqual(@as(u64, 4), result.bytes_consumed);
}

test "EOF inside a line is UnexpectedEndOfHeader" {
    var reader: std.Io.Reader = .fixed("ply\nformat ascii 1.0");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, .{});
    defer line_reader.deinit();

    _ = try line_reader.nextLine();
    try std.testing.expectError(error.UnexpectedEndOfHeader, line_reader.nextLine());
}

test "empty input yields a clean EOF" {
    var reader: std.Io.Reader = .fixed("");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, .{});
    defer line_reader.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try line_reader.nextLine());
    try std.testing.expectEqual(@as(u64, 0), line_reader.bytes_consumed);
}

test "line exactly at the configured maximum is accepted" {
    const allocator = std.testing.allocator;

    var options = Options{};
    options.limits.max_header_line_bytes = 4;

    var reader: std.Io.Reader = .fixed("abcd\nefg\n");
    var line_reader = HeaderLineReader.init(&reader, allocator, options);
    defer line_reader.deinit();

    try std.testing.expectEqualStrings("abcd", (try line_reader.nextLine()).?);
    // The next content byte would exceed the line limit...
    try std.testing.expectEqualStrings("efg", (try line_reader.nextLine()).?);
}

test "line exceeding the configured maximum is rejected" {
    var options = Options{};
    options.limits.max_header_line_bytes = 4;

    var reader: std.Io.Reader = .fixed("abcde\n");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, options);
    defer line_reader.deinit();
    try std.testing.expectError(error.HeaderLineTooLong, line_reader.nextLine());
}

test "line limit does not count the CRLF terminator bytes" {
    // Content of exactly max_line_bytes bytes terminated by CRLF: accepted,
    // because the stripped \r never counts toward line content.
    var options = Options{};
    options.limits.max_header_line_bytes = 4;

    var reader: std.Io.Reader = .fixed("abcd\r\n");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, options);
    defer line_reader.deinit();
    try std.testing.expectEqualStrings("abcd", (try line_reader.nextLine()).?);
}

test "header exactly at the total byte limit is accepted" {
    // "ply\nformat ascii 1.0\nend_header\n" is exactly 32 bytes.
    const bytes = "ply\nformat ascii 1.0\nend_header\n";
    try std.testing.expectEqual(@as(usize, 32), bytes.len);

    var options = Options{};
    options.limits.max_header_bytes = 32;

    var reader: std.Io.Reader = .fixed(bytes);
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, options);
    defer line_reader.deinit();

    _ = try line_reader.nextLine();
    _ = try line_reader.nextLine();
    _ = try line_reader.nextLine();
    try std.testing.expectEqual(@as(?[]const u8, null), try line_reader.nextLine());
    try std.testing.expectEqual(@as(u64, 32), line_reader.bytes_consumed);
}

test "header exceeding the total byte limit is rejected" {
    const bytes = "ply\nformat ascii 1.0\nend_header\n";

    var options = Options{};
    options.limits.max_header_bytes = 31;

    var reader: std.Io.Reader = .fixed(bytes);
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, options);
    defer line_reader.deinit();

    _ = try line_reader.nextLine(); // "ply" (4 bytes)
    _ = try line_reader.nextLine(); // "format ascii 1.0" (17 bytes)
    // Byte 32 exceeds the 31-byte limit while reading "end_header\n".
    try std.testing.expectError(error.HeaderTooLarge, line_reader.nextLine());
}

test "total limit counts every byte including terminators" {
    // 4-byte content + newline repeated; the limit hits exactly on the
    // final terminator.
    var options = Options{};
    options.limits.max_header_bytes = 8; // "aa\nbb\nc\n" is 8 bytes

    var reader: std.Io.Reader = .fixed("aa\nbb\nc\nxx\n");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, options);
    defer line_reader.deinit();

    _ = try line_reader.nextLine();
    _ = try line_reader.nextLine();
    _ = try line_reader.nextLine();
    try std.testing.expectError(error.HeaderTooLarge, line_reader.nextLine());
}

test "one-byte-at-a-time reader produces identical results" {
    const allocator = std.testing.allocator;
    const bytes = "ply\r\nformat ascii 1.0\r\nend_header\r\nBODY";

    // The caller's buffer is far smaller than the longest line.
    var underlying: std.Io.Reader = .fixed(bytes);
    var small_buf: [1]u8 = undefined;
    var limited: std.Io.Reader.Limited = .init(&underlying, .unlimited, &small_buf);

    var line_reader = HeaderLineReader.init(&limited.interface, allocator, .{});
    defer line_reader.deinit();

    try std.testing.expectEqualStrings("ply", (try line_reader.nextLine()).?);
    try std.testing.expectEqualStrings("format ascii 1.0", (try line_reader.nextLine()).?);
    try std.testing.expectEqualStrings("end_header", (try line_reader.nextLine()).?);

    // Exactly the terminator bytes were consumed: 5 + 18 + 12 = 35.
    try std.testing.expectEqual(@as(u64, 35), line_reader.bytes_consumed);
    try std.testing.expectEqual(@as(usize, 35), underlying.seek);
    try std.testing.expectEqual(@as(u8, 'B'), try limited.interface.takeByte());
}

test "irregular fragment reader produces identical results" {
    const allocator = std.testing.allocator;
    const bytes = "ply\nformat ascii 1.0\nend_header\n0123456789";

    var frag_buf: [4]u8 = undefined;
    var chunked: ChunkedReader = .init(bytes, &.{ 5, 1, 3, 2, 7 }, &frag_buf);

    var line_reader = HeaderLineReader.init(&chunked.interface, allocator, .{});
    defer line_reader.deinit();

    try std.testing.expectEqualStrings("ply", (try line_reader.nextLine()).?);
    try std.testing.expectEqualStrings("format ascii 1.0", (try line_reader.nextLine()).?);
    try std.testing.expectEqualStrings("end_header", (try line_reader.nextLine()).?);
    // 4 + 17 + 11 = 32 bytes consumed; the body's first byte follows.
    try std.testing.expectEqual(@as(u64, 32), line_reader.bytes_consumed);
    try std.testing.expectEqual(@as(u8, '0'), try chunked.interface.takeByte());
}

/// A reader that delivers chunks of varying sizes (smaller than any of the
/// header lines), exercising fragmentation independence.
const ChunkedReader = struct {
    interface: std.Io.Reader,
    source: []const u8,
    pos: usize = 0,
    chunk_index: usize = 0,
    pattern: []const usize,

    fn init(source: []const u8, pattern: []const usize, buffer: []u8) ChunkedReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .source = source,
            .pattern = pattern,
        };
    }

    fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
        return error.ReadFailed; // never reached via takeByte/readVec
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data; // contract: implementations fill r.buffer and advance r.end
        const self: *ChunkedReader = @fieldParentPtr("interface", r);
        if (self.pos >= self.source.len) return error.EndOfStream;

        const space = r.buffer.len - r.end;
        if (space == 0) return 0;
        const chunk = self.pattern[self.chunk_index % self.pattern.len];
        self.chunk_index += 1;
        const n = @min(@min(space, chunk), self.source.len - self.pos);
        @memcpy(r.buffer[r.end..][0..n], self.source[self.pos..][0..n]);
        self.pos += n;
        r.end += n;
        return n;
    }
};

test "failing reader is distinguishable from malformed syntax" {
    var fail_buf: [1]u8 = undefined;
    var failing: FailingReader = .init(&fail_buf);

    var line_reader = HeaderLineReader.init(&failing.interface, std.testing.allocator, .{});
    defer line_reader.deinit();
    try std.testing.expectError(error.ReadFailed, line_reader.nextLine());
    try std.testing.expectEqual(@as(u64, 0), line_reader.bytes_consumed);
}

const FailingReader = struct {
    interface: std.Io.Reader,

    fn init(buffer: []u8) FailingReader {
        return .{ .interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
        return error.ReadFailed;
    }

    fn readVec(_: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
        return error.ReadFailed;
    }
};

test "embedded NUL bytes are passed through for directive-level validation" {
    // The line reader is byte-agnostic: it returns the content and counts
    // the byte; rejecting NUL is the directive parser's policy.
    const allocator = std.testing.allocator;
    var result = try readAll(allocator, "a\x00b\n", .{});
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.lines.items.len);
    try std.testing.expectEqual(@as(usize, 3), result.lines.items[0].len);
    try std.testing.expectEqual(@as(u8, 0), result.lines.items[0][1]);
    try std.testing.expectEqual(@as(u64, 4), result.bytes_consumed);
}

test "body bytes immediately after end_header are untouched" {
    const allocator = std.testing.allocator;
    const bytes = "ply\nformat binary_little_endian 1.0\nend_header\n\x00\xFF\x10\x20";

    var reader: std.Io.Reader = .fixed(bytes);
    var line_reader = HeaderLineReader.init(&reader, allocator, .{});
    defer line_reader.deinit();

    _ = try line_reader.nextLine(); // "ply"
    _ = try line_reader.nextLine(); // "format binary_little_endian 1.0"
    _ = try line_reader.nextLine(); // "end_header"
    // 4 + 32 + 11 = 47 consumed; the first body byte follows.
    try std.testing.expectEqual(@as(u64, 47), line_reader.bytes_consumed);
    try std.testing.expectEqual(@as(usize, 47), reader.seek);
    try std.testing.expectEqual(@as(u8, 0x00), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0xFF), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0x10), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 0x20), try reader.takeByte());
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
}

test "deinit releases scratch storage and leaves the stream untouched" {
    var reader: std.Io.Reader = .fixed("a\nb\n");
    var line_reader = HeaderLineReader.init(&reader, std.testing.allocator, .{});
    _ = try line_reader.nextLine();
    line_reader.deinit();
    // Reader position is unaffected by deinit.
    try std.testing.expectEqual(@as(usize, 2), reader.seek);
}
