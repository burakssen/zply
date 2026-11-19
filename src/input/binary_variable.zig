//! Phase 10 incremental, non-seekable variable-length binary record reader.
//!
//! This layer deliberately does not know about Parser, scheduling, or batch
//! storage. It uses the allocation-free structural scanner to determine the
//! next required field extent, reserves scratch *before* advancing the caller's
//! Reader, and retains all consumed bytes when allocation pressure interrupts
//! a record. The caller may retry with the same (possibly budgeted) allocator.
//!
//! A `RecordView` borrows this reader's scratch allocation and remains valid
//! until the next `readRecord` or `deinit`. There is no implicit lookahead.
const std = @import("std");
const boundary = @import("binary_boundary.zig");
const layout_mod = @import("../format/layout.zig");

pub const RecordError = boundary.ScanError || error{
    TruncatedRecord,
    TruncatedListCount,
    TruncatedListPayload,
    ReadFailed,
    OutOfMemory,
    SizeOverflow,
    InvalidReaderState,
};

pub const RecordView = struct {
    bytes: []const u8,
    /// Relative to the first binary body byte, not the underlying file offset.
    body_offset: u64,
    /// Global ordinal among records successfully read by this reader.
    record_index: u64,
    total_list_items: usize,
};

pub const Reader = struct {
    scratch: std.ArrayList(u8) = .empty,
    /// Physical bytes consumed from the borrowed source, including a partial record.
    body_bytes_consumed: u64 = 0,
    /// Bytes belonging to records that have been completed successfully.
    completed_body_bytes: u64 = 0,
    completed_record_count: u64 = 0,
    record_start: u64 = 0,
    in_progress: bool = false,
    failed: bool = false,
    /// Most recently discovered structural requirement; also useful for diagnostics.
    requirement: ?boundary.Incomplete = null,
    active_element_index: ?usize = null,
    /// Incremental scanner for the in-progress record. Retains per-property
    /// progress so extending a partially received list payload does not
    /// rescan earlier properties or re-decode the list count.
    scanner: ?boundary.Scanner = null,
    /// Number of contiguous input spans copied into scratch. Useful for
    /// measuring the producer's work; a buffered reader can yield many bytes
    /// in one span, while a one-byte source necessarily yields one at a time.
    copied_spans: u64 = 0,

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        self.scratch.deinit(allocator);
        self.* = .{};
    }

    /// Reads exactly one complete variable-width binary record. Does not seek,
    /// buffer bytes from the next record, or decode scalar/list item values.
    ///
    /// On OutOfMemory, `scratch`, `requirement`, `record_start` and the
    /// underlying reader position remain consistent for a retry. Allocation
    /// failures are not interpreted as permanent budget insufficiency here:
    /// only the owning parser can distinguish unavailable leased capacity
    /// from a permanently too-small configured budget.
    pub fn readRecord(
        self: *Reader,
        allocator: std.mem.Allocator,
        source: *std.Io.Reader,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        limits: boundary.Limits,
    ) RecordError!RecordView {
        return self.readRecordWithCounts(allocator, source, layout, endian, limits, null);
    }

    /// Optional caller-owned counts are filled by the same structural scan
    /// that determines record boundaries, avoiding an extra list-count pass
    /// during chunk assembly. Scalar properties contribute zero.
    pub fn readRecordWithCounts(
        self: *Reader,
        allocator: std.mem.Allocator,
        source: *std.Io.Reader,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        limits: boundary.Limits,
        counts_out: ?[]usize,
    ) RecordError!RecordView {
        if (counts_out) |counts| {
            if (counts.len < layout.properties.len) return error.InvalidLayout;
        }
        if (self.failed) return error.InvalidReaderState;
        if (layout.fixed_record_size != null or layout.minimum_record_size == 0) return error.InvalidLayout;
        if (!self.in_progress) {
            self.record_start = self.body_bytes_consumed;
            self.scratch.clearRetainingCapacity();
            self.in_progress = true;
            self.active_element_index = layout.element_index;
            self.requirement = null;
            const scanner = boundary.Scanner.init(layout, endian, limits, counts_out) catch |err| {
                self.failed = true;
                return err;
            };
            self.scanner = scanner;
            self.scanner.?.reset();
        } else if (self.active_element_index != layout.element_index) {
            return error.InvalidReaderState;
        }

        while (true) {
            const result = self.scanner.?.scan(self.scratch.items) catch |err| {
                self.failed = true;
                return err;
            };
            switch (result) {
                .complete => |complete| {
                    if (complete.byte_length != self.scratch.items.len) {
                        self.failed = true;
                        return error.InvalidLayout;
                    }
                    const next_count = std.math.add(u64, self.completed_record_count, 1) catch {
                        self.failed = true;
                        return error.SizeOverflow;
                    };
                    const view: RecordView = .{
                        .bytes = self.scratch.items,
                        .body_offset = self.record_start,
                        .record_index = self.completed_record_count,
                        .total_list_items = complete.total_list_items,
                    };
                    self.completed_record_count = next_count;
                    self.completed_body_bytes = self.body_bytes_consumed;
                    self.in_progress = false;
                    self.active_element_index = null;
                    self.requirement = null;
                    self.scanner = null;
                    return view;
                },
                .incomplete => |missing| {
                    self.requirement = missing;
                    if (missing.required_total <= self.scratch.items.len) {
                        self.failed = true;
                        return error.InvalidLayout;
                    }
                    // Do not request the entire declared payload at once:
                    // a long list may grow in bounded increments and preserve
                    // an already-consumed prefix if a later growth fails.
                    // Doubling until 4 KiB limits both rescans and peak growth.
                    const step = @min(@as(usize, 4096), @max(@as(usize, 32), self.scratch.capacity));
                    const wanted = std.math.add(usize, self.scratch.items.len, @min(step, missing.required_total - self.scratch.items.len)) catch {
                        self.failed = true;
                        return error.SizeOverflow;
                    };
                    // Precise capacity avoids allocating beyond max_record_bytes.
                    // The allocator may be a parser-budgeted allocator.
                    try self.scratch.ensureTotalCapacityPrecise(allocator, wanted);
                    // Copy whole buffered spans. Unlike readSliceShort(),
                    // peekGreedy(1) does not consume bytes before returning
                    // ReadFailed. We commit only after the copy, so an I/O
                    // failure has an exact byte count even on a non-seekable
                    // source and does not corrupt a partial record.
                    //
                    // The span is capped at the scanner's next structural
                    // requirement: never read into the next record/property.
                    while (self.scratch.items.len < wanted) {
                        const available = source.peekGreedy(1) catch |err| {
                            self.failed = true;
                            return switch (err) {
                                error.EndOfStream => switch (missing.stage) {
                                    .scalar => error.TruncatedRecord,
                                    .list_count => error.TruncatedListCount,
                                    .list_items => error.TruncatedListPayload,
                                },
                                error.ReadFailed => error.ReadFailed,
                            };
                        };
                        const n = @min(available.len, wanted - self.scratch.items.len);
                        const n64 = std.math.cast(u64, n) orelse {
                            self.failed = true;
                            return error.SizeOverflow;
                        };
                        const next_consumed = std.math.add(u64, self.body_bytes_consumed, n64) catch {
                            self.failed = true;
                            return error.SizeOverflow;
                        };
                        const next_spans = std.math.add(u64, self.copied_spans, 1) catch {
                            self.failed = true;
                            return error.SizeOverflow;
                        };
                        const start = self.scratch.items.len;
                        @memcpy(self.scratch.items.ptr[start .. start + n], available[0..n]);
                        source.toss(n);
                        self.scratch.items.len += n;
                        self.body_bytes_consumed = next_consumed;
                        self.copied_spans = next_spans;
                    }
                },
            }
        }
    }
};
