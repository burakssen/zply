//! Phase 10 record-aligned binary-variable chunk staging.
//!
//! This coordinator-only builder owns the incremental Reader and its scratch,
//! plus budgetable raw bytes, record boundaries, and per-property list totals.
//! It does not allocate in a decoding task, seek, or access Parser internals.
//! A returned Chunk borrows the builder until `consume` or `deinit`.
const std = @import("std");
const variable = @import("binary_variable.zig");
const boundary = @import("binary_boundary.zig");
const layout_mod = @import("../format/layout.zig");

pub const BuildError = variable.RecordError || error{InvalidBuilderState};

pub const Chunk = struct {
    element_index: usize,
    first_record: u64,
    record_count: usize,
    first_body_byte_offset: u64,
    bytes: []const u8,
    /// Always `record_count + 1` entries, beginning at zero and ending at
    /// `bytes.len`. Every range contains exactly one complete binary record.
    offsets: []const usize,
    /// Indexed by compiled property index. Scalars have zero total items.
    list_item_totals: []const usize,
};

pub const Builder = struct {
    record_reader: variable.Reader = .{},
    bytes: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(usize) = .empty,
    totals: std.ArrayList(usize) = .empty,
    // Counts from the existing reader's final structural scan; no extra
    // per-record scan or per-record count allocation is necessary.
    counts: std.ArrayList(usize) = .empty,
    element_index: usize = 0,
    first_record: u64 = 0,
    first_body_byte_offset: u64 = 0,
    record_count: usize = 0,
    active: bool = false,
    ready: bool = false,
    pending: bool = false,
    pending_element_index: usize = 0,
    /// A terminal reader error discovered after an earlier complete record.
    /// Deliver the valid prefix first, then surface this error on the next fill.
    terminal_error: ?BuildError = null,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.record_reader.deinit(allocator);
        self.bytes.deinit(allocator);
        self.offsets.deinit(allocator);
        self.totals.deinit(allocator);
        self.counts.deinit(allocator);
        self.* = .{};
    }

    /// Synchronize the logical byte counter after a preceding fixed-width
    /// element was consumed by a different input producer. This is NOT a
    /// seek: the caller must already have advanced the physical source to
    /// this byte position, measured from the PLY body start. Never reset a
    /// partially read, pending, or staged variable-length record.
    pub fn synchronizeBodyOffset(self: *Builder, offset: u64) BuildError!void {
        if (self.active or self.ready or self.pending or
            self.record_reader.in_progress or self.record_reader.failed or
            self.record_reader.completed_body_bytes != self.record_reader.body_bytes_consumed or
            offset < self.record_reader.body_bytes_consumed) return error.InvalidBuilderState;
        self.record_reader.body_bytes_consumed = offset;
        self.record_reader.completed_body_bytes = offset;
    }

    /// Stage at most `records_remaining` records belonging to `layout`.
    /// This is the number of records not yet emitted by this builder, rather
    /// than the element's original declared count. A zero count consumes no
    /// input. `first_record` is the element-relative ordinal of that range.
    ///
    /// The first complete record may exceed `preferred_bytes` (but not the
    /// hard record/budget limits). Later records are held in reader scratch if
    /// admitting them would exceed the preferred size. On OutOfMemory while
    /// appending or reading a following record, already staged records are
    /// returned as a valid chunk; any pending or partial record is retained.
    /// With no staged records, OutOfMemory propagates and the same arguments
    /// can be retried after the owner makes more memory available.
    pub fn fill(
        self: *Builder,
        allocator: std.mem.Allocator,
        source: *std.Io.Reader,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        limits: boundary.Limits,
        preferred_bytes: usize,
        first_record: u64,
        records_remaining: u64,
    ) BuildError!?Chunk {
        if (preferred_bytes == 0 or layout.fixed_record_size != null or layout.minimum_record_size == 0)
            return error.InvalidBuilderState;
        if (!self.ready) {
            if (self.terminal_error) |terminal| return terminal;
        }
        if (self.ready) {
            if (layout.element_index != self.element_index or first_record != self.first_record)
                return error.InvalidBuilderState;
            return self.view();
        }
        if (!self.active) {
            if (records_remaining == 0) return null;
            if ((self.pending and self.pending_element_index != layout.element_index) or
                (self.record_reader.in_progress and self.record_reader.active_element_index != layout.element_index))
                return error.InvalidBuilderState;
            // Perform all schema-size allocations before consuming input.
            try self.totals.resize(allocator, layout.properties.len);
            try self.counts.resize(allocator, layout.properties.len);
            @memset(self.totals.items, 0);
            self.element_index = layout.element_index;
            self.first_record = first_record;
            self.active = true;
        } else if (layout.element_index != self.element_index or first_record != self.first_record) {
            return error.InvalidBuilderState;
        }

        while (@as(u64, @intCast(self.record_count)) < records_remaining) {
            if (self.record_count > 0 and self.bytes.items.len >= preferred_bytes) break;
            if (!self.pending) {
                _ = self.record_reader.readRecordWithCounts(
                    allocator, source, layout, endian, limits, self.counts.items,
                ) catch |err| {
                    if (self.record_count > 0) {
                        if (err != error.OutOfMemory) self.terminal_error = err;
                        return self.finish();
                    }
                    return err;
                };
                self.pending = true;
                self.pending_element_index = layout.element_index;
            }
            if (self.pending_element_index != layout.element_index) return error.InvalidBuilderState;
            const record = self.record_reader.scratch.items;
            if (self.record_count > 0 and
                (self.bytes.items.len >= preferred_bytes or
                record.len > preferred_bytes - self.bytes.items.len)) break;
            self.appendPending(allocator, layout) catch |err| {
                if (err == error.OutOfMemory and self.record_count > 0) return self.finish();
                return err;
            };
        }
        if (self.record_count == 0) return error.InvalidBuilderState;
        return self.finish();
    }

    /// Call only after all consumers have copied/prepared the borrowed data.
    /// A full chunk is never dropped in response to a failed admission.
    pub fn consume(self: *Builder) void {
        std.debug.assert(self.ready);
        self.bytes.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();
        self.record_count = 0;
        self.ready = false;
        self.active = false;
        // `pending` may refer to a completed but not yet staged record.
        // Neither its scratch nor its per-property counts may be destroyed.
    }

    /// Commit an admitted prefix without discarding the remaining complete
    /// records, any pending lookahead record, or a partially consumed record.
    /// The caller has already checked the prefix totals and prepared its own
    /// immutable input/output storage, so this operation cannot allocate.
    pub fn consumePrefix(self: *Builder, n: usize, prefix_totals: []const usize) void {
        std.debug.assert(self.ready and n > 0 and n <= self.record_count);
        std.debug.assert(prefix_totals.len == self.totals.items.len);
        if (n == self.record_count) {
            self.consume();
            return;
        }
        const byte_count = self.offsets.items[n];
        const rest = self.bytes.items.len - byte_count;
        std.mem.copyForwards(u8, self.bytes.items[0..rest], self.bytes.items[byte_count..]);
        self.bytes.items.len = rest;
        const remaining = self.record_count - n;
        for (0..remaining + 1) |i| {
            self.offsets.items[i] = self.offsets.items[n + i] - byte_count;
        }
        self.offsets.items.len = remaining + 1;
        for (self.totals.items, prefix_totals) |*total, used| {
            std.debug.assert(total.* >= used);
            total.* -= used;
        }
        self.first_record += @as(u64, @intCast(n));
        self.first_body_byte_offset += @as(u64, @intCast(byte_count));
        self.record_count = remaining;
    }

    fn view(self: *const Builder) Chunk {
        std.debug.assert(self.ready);
        return .{
            .element_index = self.element_index,
            .first_record = self.first_record,
            .record_count = self.record_count,
            .first_body_byte_offset = self.first_body_byte_offset,
            .bytes = self.bytes.items,
            .offsets = self.offsets.items,
            .list_item_totals = self.totals.items,
        };
    }

    fn finish(self: *Builder) Chunk {
        std.debug.assert(self.record_count > 0);
        self.ready = true;
        return self.view();
    }

    fn appendPending(self: *Builder, allocator: std.mem.Allocator, layout: *const layout_mod.ElementLayout) BuildError!void {
        std.debug.assert(self.pending);
        const raw = self.record_reader.scratch.items;
        if (self.counts.items.len != layout.properties.len or self.totals.items.len != layout.properties.len)
            return error.InvalidBuilderState;
        // Checked arithmetic and all potential allocations occur before
        // updating record_count, offsets, totals, or the raw byte slice.
        _ = std.math.add(usize, self.bytes.items.len, raw.len) catch return error.SizeOverflow;
        const next_count = std.math.add(usize, self.record_count, 1) catch return error.SizeOverflow;
        for (self.totals.items, self.counts.items) |old, count| {
            _ = std.math.add(usize, old, count) catch return error.SizeOverflow;
        }
        try self.bytes.ensureUnusedCapacity(allocator, raw.len);
        try self.offsets.ensureUnusedCapacity(allocator, if (self.record_count == 0) 2 else 1);
        if (self.record_count == 0) {
            self.first_body_byte_offset = self.record_reader.record_start;
            self.offsets.appendAssumeCapacity(0);
        }
        self.bytes.appendSliceAssumeCapacity(raw);
        self.offsets.appendAssumeCapacity(self.bytes.items.len);
        for (self.totals.items, self.counts.items) |*total, count| total.* += count;
        self.record_count = next_count;
        self.pending = false;
    }
};
