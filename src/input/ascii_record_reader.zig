//! Strict, bounded one-line-per-record ASCII PLY reader.
//! A scratch view remains valid until the next read; no seeking or lookahead.
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
        while (true) {
            const ch = if (self.pending_byte) |saved| blk: {
                self.pending_byte = null;
                break :blk saved;
            } else blk: {
                const next = reader.takeByte() catch |err| switch (err) {
                    error.EndOfStream => return error.TruncatedAsciiBody,
                    error.ReadFailed => return error.ReadFailed,
                };
                self.body_bytes_consumed = std.math.add(u64, self.body_bytes_consumed, 1) catch return error.SizeOverflow;
                break :blk next;
            };
            if (ch == '\n') break;
            if (ch == '\r') {
                const next = reader.takeByte() catch |err| switch (err) {
                    error.EndOfStream => return error.TruncatedAsciiBody,
                    error.ReadFailed => return error.ReadFailed,
                };
                self.body_bytes_consumed = std.math.add(u64, self.body_bytes_consumed, 1) catch return error.SizeOverflow;
                if (next != '\n') return error.InvalidLineEnding;
                break;
            }
            if (ch == 0) return error.InvalidAsciiRecord;
            if (self.scratch.items.len >= max_record_bytes) return error.RecordTooLarge;
            self.scratch.append(allocator, ch) catch {
                // takeByte() has advanced the borrowed non-seekable reader.
                // Keep this byte until the next successful allocation.
                self.pending_byte = ch;
                return error.OutOfMemory;
            };
        }
        self.in_progress = false;
        self.line_number += 1;
        return .{ .bytes = self.scratch.items, .body_offset = self.last_start, .line_number = self.last_line_number };
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
            // The failure is transient. The next call must continue the
            // partially consumed line, not start at a new record boundary.
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
    // FailingAllocator may exercise only initial allocation failure because
    // ArrayList can grow through resize/remap operations. A separate test
    // below deterministically forces a failure after consuming some bytes.
}

test "ASCII reader recovers from deterministic mid-record memory pressure" {
    var input_bytes: [516]u8 = undefined;
    @memset(input_bytes[0..512], '7');
    @memcpy(input_bytes[512..516], "\r\n8\n");

    // An ArrayList's first append can request a larger allocation than
    // 96 bytes. Allocate a small, exact scratch capacity *before* narrowing
    // the allocator budget: this guarantees that OutOfMemory happens during
    // a later growth, after some input bytes have already been preserved.
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
    try std.testing.expect(line_reader.scratch.items.len > 0);
    try std.testing.expect(line_reader.scratch.items.len < 512);
    try std.testing.expectEqual(@as(?u8, '7'), line_reader.pending_byte);
    try std.testing.expectEqual(@as(u64, @intCast(line_reader.scratch.items.len + 1)), line_reader.body_bytes_consumed);

    // Retry the same partially consumed line, including the saved byte,
    // after admitting more allocation capacity. No seek is performed.
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
