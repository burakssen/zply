//! Strict, bounded one-line-per-record ASCII PLY reader.
//! A scratch view remains valid until the next read; no seeking or lookahead.
//!
//! Phase 12 M9: the sequential scanner consumes the reader's buffered span in
//! bulk instead of one `takeByte()` call per character. It still discovers
//! every LF, CRLF, NUL and record-size violation at exactly the same logical
//! position, and it commits a span to scratch only after its capacity has been
//! admitted. An allocation failure therefore leaves the borrowed reader
//! untouched and the record retryable without a saved pending byte.
const std = @import("std");

pub const RecordError = error{ TruncatedAsciiBody, InvalidAsciiRecord, InvalidLineEnding, RecordTooLarge, ReadFailed, OutOfMemory, SizeOverflow };
pub const RecordView = struct {
    bytes: []const u8,
    body_offset: u64,
    line_number: u64,
    terminated_by_newline: bool = true,
};

pub const Reader = struct {
    scratch: std.ArrayList(u8) = .empty,
    body_bytes_consumed: u64 = 0,
    line_number: u64 = 0,
    last_start: u64 = 0,
    last_line_number: u64 = 0,
    /// A line may be partially consumed when its scratch buffer cannot grow.
    /// Retain both the partial line and the byte that failed to append so a
    /// retry never relies on seeking the caller's reader backwards.
    in_progress: bool = false,
    /// Only used by the pre-Phase-12 byte-at-a-time path. Bulk staging admits
    /// capacity before consuming, so new reads never set this field.
    pending_byte: ?u8 = null,

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        self.scratch.deinit(allocator);
    }

    pub fn readRecord(self: *Reader, allocator: std.mem.Allocator, reader: *std.Io.Reader, max_record_bytes: usize) RecordError!RecordView {
        if (!self.in_progress) {
            self.scratch.clearRetainingCapacity();
            self.last_start = self.body_bytes_consumed;
            self.last_line_number = self.line_number + 1;
            self.in_progress = true;
        }
        // Preserve a byte saved by a pre-bulk caller. New calls never create
        // one, but accepting it keeps the retry contract total.
        if (self.pending_byte) |saved| {
            self.pending_byte = null;
            try self.appendContent(allocator, &.{saved}, max_record_bytes);
        }
        while (true) {
            const available = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return error.TruncatedAsciiBody,
                error.ReadFailed => return error.ReadFailed,
            };
            if (available.len == 0) return error.TruncatedAsciiBody;

            // One pass over the reader's currently buffered bytes. `findAny`
            // is allowed to use a vectorized implementation; the fallback is
            // still a simple linear scan. Every delimiter has the same
            // correctness significance as in the byte-at-a-time scanner.
            const special = std.mem.indexOfAny(u8, available, "\n\r\x00");
            const content_len = special orelse available.len;

            // Admit capacity before consuming anything. On failure the
            // reader position, scratch contents and byte counters are all
            // unchanged, so the caller can retry this same record.
            try self.appendContent(allocator, available[0..content_len], max_record_bytes);

            if (special == null) {
                reader.toss(available.len);
                self.body_bytes_consumed = std.math.add(
                    u64,
                    self.body_bytes_consumed,
                    @as(u64, @intCast(available.len)),
                ) catch return error.SizeOverflow;
                continue;
            }

            switch (available[special.?]) {
                '\n' => {
                    const consumed = content_len + 1;
                    reader.toss(consumed);
                    self.body_bytes_consumed = std.math.add(
                        u64,
                        self.body_bytes_consumed,
                        @as(u64, @intCast(consumed)),
                    ) catch return error.SizeOverflow;
                },
                '\r' => {
                    // Consume the CR, then require exactly one LF. This is
                    // the same accepted grammar as the original scanner and
                    // reports the same truncated-input error at EOF.
                    const consumed = content_len + 1;
                    reader.toss(consumed);
                    self.body_bytes_consumed = std.math.add(
                        u64,
                        self.body_bytes_consumed,
                        @as(u64, @intCast(consumed)),
                    ) catch return error.SizeOverflow;
                    const next = reader.takeByte() catch |err| switch (err) {
                        error.EndOfStream => return error.TruncatedAsciiBody,
                        error.ReadFailed => return error.ReadFailed,
                    };
                    self.body_bytes_consumed = std.math.add(u64, self.body_bytes_consumed, 1) catch return error.SizeOverflow;
                    if (next != '\n') return error.InvalidLineEnding;
                },
                else => return error.InvalidAsciiRecord,
            }
            break;
        }
        self.in_progress = false;
        self.line_number += 1;
        return .{ .bytes = self.scratch.items, .body_offset = self.last_start, .line_number = self.last_line_number };
    }

    /// Appends one already-validated content span. The length limit matches
    /// the original per-byte rule: a record's content may be exactly
    /// `max_record_bytes` long, excluding the line terminator.
    fn appendContent(self: *Reader, allocator: std.mem.Allocator, content: []const u8, max_record_bytes: usize) RecordError!void {
        if (content.len == 0) return;
        if (content.len > max_record_bytes -| self.scratch.items.len) return error.RecordTooLarge;
        try self.scratch.ensureUnusedCapacity(allocator, content.len);
        self.scratch.appendSliceAssumeCapacity(content);
    }
};

test "ASCII reader retries after allocator failures without losing consumed bytes" {
    const a = std.testing.allocator;
    var input_bytes: [516]u8 = undefined;
    @memset(input_bytes[0..512], '7');
    @memcpy(input_bytes[512..516], "\r\n8\n");

    var failures: usize = 0;
    for (0..12) |failure_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure_index });
        var source: std.Io.Reader = .fixed(&input_bytes);
        var line_reader: Reader = .{};
        defer line_reader.deinit(failing.allocator());

        const first = line_reader.readRecord(failing.allocator(), &source, 512) catch |err| blk: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expect(line_reader.in_progress);
            // Bulk staging commits atomically: no input byte was consumed
            // and no pending byte is required. The next call re-reads the
            // same buffered span.
            try std.testing.expect(line_reader.pending_byte == null);
            failing.fail_index = std.math.maxInt(usize);
            break :blk try line_reader.readRecord(failing.allocator(), &source, 512);
        };
        try std.testing.expectEqual(@as(usize, 512), first.bytes.len);
        for (first.bytes) |byte| try std.testing.expectEqual(@as(u8, '7'), byte);
        try std.testing.expectEqual(@as(u64, 0), first.body_offset);
        try std.testing.expectEqual(@as(u64, 1), first.line_number);
        try std.testing.expectEqual(@as(u64, 514), line_reader.body_bytes_consumed);
        try std.testing.expect(!line_reader.in_progress);
        try std.testing.expect(line_reader.pending_byte == null);

        const second = try line_reader.readRecord(failing.allocator(), &source, 512);
        try std.testing.expectEqualStrings("8", second.bytes);
        try std.testing.expectEqual(@as(u64, 514), second.body_offset);
        try std.testing.expectEqual(@as(u64, 2), second.line_number);
        try std.testing.expectEqual(@as(u64, 516), line_reader.body_bytes_consumed);
    }
    try std.testing.expect(failures > 0);
}

test "ASCII reader recovers from deterministic mid-record memory pressure" {
    var input_bytes: [516]u8 = undefined;
    @memset(input_bytes[0..512], '7');
    @memcpy(input_bytes[512..516], "\r\n8\n");

    // Keep the same FixedBufferAllocator alive when expanding the budget.
    var backing: [8192]u8 = undefined;
    var limited = std.heap.FixedBufferAllocator.init(backing[0..]);
    var source: std.Io.Reader = .fixed(&input_bytes);
    var line_reader: Reader = .{};
    defer line_reader.deinit(limited.allocator());

    try line_reader.scratch.ensureTotalCapacityPrecise(limited.allocator(), 32);
    try std.testing.expectEqual(@as(usize, 32), line_reader.scratch.capacity);
    limited.buffer = backing[0..96];

    try std.testing.expectError(error.OutOfMemory, line_reader.readRecord(limited.allocator(), &source, 512));
    try std.testing.expect(line_reader.in_progress);
    // The bulk scanner consumes nothing when capacity admission fails.
    try std.testing.expectEqual(@as(usize, 0), line_reader.scratch.items.len);
    try std.testing.expect(line_reader.pending_byte == null);
    try std.testing.expectEqual(@as(u64, 0), line_reader.body_bytes_consumed);

    // Retry the same buffered line after admitting more allocation capacity.
    limited.buffer = backing[0..];
    const first = try line_reader.readRecord(limited.allocator(), &source, 512);
    try std.testing.expectEqual(@as(usize, 512), first.bytes.len);
    for (first.bytes) |byte| try std.testing.expectEqual(@as(u8, '7'), byte);
    try std.testing.expectEqual(@as(u64, 0), first.body_offset);
    try std.testing.expectEqual(@as(u64, 1), first.line_number);
    try std.testing.expectEqual(@as(u64, 514), line_reader.body_bytes_consumed);
    try std.testing.expect(!line_reader.in_progress);
    try std.testing.expect(line_reader.pending_byte == null);

    const second = try line_reader.readRecord(limited.allocator(), &source, 512);
    try std.testing.expectEqualStrings("8", second.bytes);
    try std.testing.expectEqual(@as(u64, 514), second.body_offset);
    try std.testing.expectEqual(@as(u64, 2), second.line_number);
    try std.testing.expectEqual(@as(u64, 516), line_reader.body_bytes_consumed);
}

test "ASCII reader preserves LF, CRLF, NUL and size errors across fragmented spans" {
    const a = std.testing.allocator;
    var source: std.Io.Reader = .fixed("1 2\r\n3\n\n4 5\n");
    var line_reader: Reader = .{};
    defer line_reader.deinit(a);

    const first = try line_reader.readRecord(a, &source, 8);
    try std.testing.expectEqualStrings("1 2", first.bytes);
    try std.testing.expectEqual(@as(u64, 5), line_reader.body_bytes_consumed);
    const second = try line_reader.readRecord(a, &source, 8);
    try std.testing.expectEqualStrings("3", second.bytes);
    const third = try line_reader.readRecord(a, &source, 8);
    try std.testing.expectEqualStrings("", third.bytes);
    const fourth = try line_reader.readRecord(a, &source, 8);
    try std.testing.expectEqualStrings("4 5", fourth.bytes);

    var nul_source: std.Io.Reader = .fixed("1\x002\n");
    var nul_reader: Reader = .{};
    defer nul_reader.deinit(a);
    try std.testing.expectError(error.InvalidAsciiRecord, nul_reader.readRecord(a, &nul_source, 16));

    var long_source: std.Io.Reader = .fixed("12345\n");
    var long_reader: Reader = .{};
    defer long_reader.deinit(a);
    try std.testing.expectError(error.RecordTooLarge, long_reader.readRecord(a, &long_source, 4));

    var cr_source: std.Io.Reader = .fixed("1\rX");
    var cr_reader: Reader = .{};
    defer cr_reader.deinit(a);
    try std.testing.expectError(error.InvalidLineEnding, cr_reader.readRecord(a, &cr_source, 16));
}
