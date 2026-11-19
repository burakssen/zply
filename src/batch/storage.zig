//! Stable, bounded, sequential batch pool. Leases must be released before
//! the parser is destroyed; copied handles do not confer another lease.
const std = @import("std");
const types = @import("../format/types.zig");
const layout_mod = @import("../format/layout.zig");
const header_mod = @import("../format/header.zig");
const binary = @import("../decode/binary.zig");
const binary_counts = @import("../decode/binary/list_count.zig");
const binary_preflight = @import("../decode/binary/preflight.zig");
const column_mod = @import("column.zig");
const fault_injection = @import("../testing/fault_injection.zig");
const ascii = @import("../decode/ascii/root.zig");
const ascii_preflight = @import("../decode/ascii/preflight.zig");
const property_mod = @import("../format/property.zig");

pub const BatchInfo = struct {
    element_index: usize,
    first_record: u64,
    record_count: usize,
    sequence: u64,
};

const Owned = union(types.ScalarType) {
    i8: []i8,
    u8: []u8,
    i16: []i16,
    u16: []u16,
    i32: []i32,
    u32: []u32,
    f32: []f32,
    f64: []f64,

    fn allocate(a: std.mem.Allocator, t: types.ScalarType, n: usize) !Owned {
        if (n == 0) return empty(t);
        return switch (t) {
            inline else => |tag| @unionInit(Owned, @tagName(tag), try a.alloc(tag.zigType(), n)),
        };
    }
    /// An empty list column has no backing allocation; its typed empty
    /// slice is a sentinel and must never be passed to the allocator.
    fn empty(t: types.ScalarType) Owned {
        return switch (t) {
            .i8 => .{ .i8 = &.{} },
            .u8 => .{ .u8 = &.{} },
            .i16 => .{ .i16 = &.{} },
            .u16 => .{ .u16 = &.{} },
            .i32 => .{ .i32 = &.{} },
            .u32 => .{ .u32 = &.{} },
            .f32 => .{ .f32 = &.{} },
            .f64 => .{ .f64 = &.{} },
        };
    }
    fn free(self: Owned, a: std.mem.Allocator) void {
        switch (self) {
            inline else => |s| if (s.len != 0) a.free(s),
        }
    }
    fn len(self: Owned) usize {
        return switch (self) {
            inline else => |s| s.len,
        };
    }
    fn allocatedBytes(self: Owned) usize {
        return switch (self) {
            inline else => |s, tag| std.math.mul(usize, s.len, tag.byteWidth()) catch @panic("column size overflow"),
        };
    }
    fn view(self: Owned, n: usize) column_mod.ScalarColumn {
        return switch (self) {
            inline else => |s, tag| @unionInit(column_mod.ScalarColumn, @tagName(tag), s[0..n]),
        };
    }
};

const Slot = struct {
    state: enum { available, filling, ready, leased } = .available,
    generation: u64 = 0,
    info: BatchInfo = undefined,
    owned: []Owned = &.{},
    columns: []column_mod.Column = &.{},
    /// One nullable offset buffer per property; null for ordinary scalars.
    list_offsets: []?[]usize = &.{},

    fn clear(self: *Slot, a: std.mem.Allocator) void {
        for (self.owned) |o| o.free(a);
        if (self.owned.len != 0) a.free(self.owned);
        if (self.columns.len != 0) a.free(self.columns);
        for (self.list_offsets) |offsets| if (offsets) |v| a.free(v);
        if (self.list_offsets.len != 0) a.free(self.list_offsets);
        self.owned = &.{};
        self.columns = &.{};
        self.list_offsets = &.{};
    }
    fn allocatedBytes(self: *const Slot) usize {
        var total = std.math.mul(usize, self.owned.len, @sizeOf(Owned)) catch @panic("slot size overflow");
        total = std.math.add(usize, total, std.math.mul(usize, self.columns.len, @sizeOf(column_mod.Column)) catch @panic("slot size overflow")) catch @panic("slot size overflow");
        total = std.math.add(usize, total, self.list_offsets.len * @sizeOf(?[]usize)) catch @panic("slot size overflow");
        for (self.list_offsets) |v| if (v) |offsets| {
            total = std.math.add(usize, total, offsets.len * @sizeOf(usize)) catch @panic("slot size overflow");
        };
        for (self.owned) |owned| total = std.math.add(usize, total, owned.allocatedBytes()) catch @panic("slot size overflow");
        return total;
    }

    fn compatible(self: *const Slot, layout: *const layout_mod.ElementLayout, n: usize) bool {
        if (self.owned.len != layout.properties.len) return false;
        if (self.list_offsets.len != 0 and self.list_offsets.len != layout.properties.len) return false;
        for (layout.properties, self.owned, 0..) |prop, own, i| {
            if (prop.scalar_type) |t| {
                if (@as(types.ScalarType, own) != t or own.len() < n) return false;
                if (self.list_offsets.len != 0 and self.list_offsets[i] != null) return false;
            } else {
                if (self.list_offsets.len == 0) return false;
                const offsets = self.list_offsets[i] orelse return false;
                if (offsets.len < n + 1) return false;
            }
        }
        return true;
    }

    fn compatibleAscii(self: *const Slot, props: []const property_mod.Property) bool {
        if (self.owned.len != props.len) return false;
        for (self.owned, props) |own, prop| {
            const t = switch (prop.kind) {
                .scalar => |tag| tag,
                .list => |li| li.item_type,
            };
            if (@as(types.ScalarType, own) != t) return false;
        }
        return true;
    }

    fn compatibleAsciiCounts(self: *const Slot, props: []const property_mod.Property, counts: []const usize) bool {
        if (!self.compatibleAscii(props) or counts.len != props.len) return false;
        for (props, self.owned, counts) |prop, own, required| {
            if (prop.kind == .list and own.len() < required) return false;
        }
        return true;
    }

    fn prepare(self: *Slot, a: std.mem.Allocator, layout: *const layout_mod.ElementLayout, n: usize, kinds: ?[]const property_mod.Property, list_counts: ?[]const usize) !void {
        if (self.compatible(layout, n) and (kinds == null or (if (list_counts) |counts| self.compatibleAsciiCounts(kinds.?, counts) else self.compatibleAscii(kinds.?)))) return;
        const owned = try a.alloc(Owned, layout.properties.len);
        errdefer a.free(owned);
        const views = try a.alloc(column_mod.Column, layout.properties.len);
        errdefer a.free(views);
        var has_lists = false;
        for (layout.properties) |prop| {
            if (prop.scalar_type == null) has_lists = true;
        }
        const lists: []?[]usize = if (has_lists) try a.alloc(?[]usize, layout.properties.len) else &.{};
        if (has_lists) @memset(lists, null);
        errdefer {
            for (lists) |entry| if (entry) |v| a.free(v);
            if (has_lists) a.free(lists);
        }
        var initialized: usize = 0;
        errdefer for (owned[0..initialized]) |o| o.free(a);
        for (layout.properties, 0..) |prop, i| {
            if (prop.scalar_type) |t| {
                owned[i] = try Owned.allocate(a, t, n);
            } else {
                const property = (kinds orelse return error.InvalidLayout)[i];
                const list = switch (property.kind) {
                    .list => |v| v,
                    else => return error.InvalidLayout,
                };
                owned[i] = if (list_counts) |counts| try Owned.allocate(a, list.item_type, counts[i]) else Owned.empty(list.item_type);
                initialized += 1;
                lists[i] = try a.alloc(usize, n + 1);
                @memset(lists[i].?, 0);
                continue;
            }
            initialized += 1;
        }
        self.clear(a);
        self.owned = owned;
        self.columns = views;
        self.list_offsets = lists;
    }
};

pub const Pool = struct {
    /// A value-only snapshot of separately allocated column arrays. Decoder
    /// tasks never access `Pool.slots`, which may be resized by the producer.
    pub const Target = struct {
        owned: []Owned,
        columns: []column_mod.Column,
        list_offsets: []?[]usize,
    };

    pub fn target(self: *Pool, id: usize) Target {
        const slot = &self.slots[id];
        std.debug.assert(slot.state == .filling);
        return .{ .owned = slot.owned, .columns = slot.columns, .list_offsets = slot.list_offsets };
    }

    const initial_slots = 2;
    allocator: std.mem.Allocator,
    slots: []Slot,

    pub const MemoryBreakdown = struct {
        decoded_bytes: usize = 0,
        retained_bytes: usize = 0,
        leased_bytes: usize = 0,
    };

    pub fn create(a: std.mem.Allocator) !*Pool {
        const p = try a.create(Pool);
        errdefer a.destroy(p);
        const slots = try a.alloc(Slot, initial_slots);
        for (slots) |*slot| slot.* = .{};
        p.* = .{ .allocator = a, .slots = slots };
        return p;
    }
    pub fn destroy(self: *Pool) void {
        for (self.slots) |*slot| {
            if (slot.state == .leased) @panic("batch lease still active during parser destruction");
        }
        for (self.slots) |*slot| {
            slot.clear(self.allocator);
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }
    pub fn hasLeases(self: *const Pool) bool {
        for (self.slots) |slot| {
            if (slot.state == .leased) return true;
        }
        return false;
    }

    pub fn memoryBreakdown(self: *const Pool) MemoryBreakdown {
        var result: MemoryBreakdown = .{};
        for (self.slots) |slot| {
            var decoded: usize = 0;
            for (slot.owned) |owned| decoded = std.math.add(usize, decoded, owned.allocatedBytes()) catch @panic("pool size overflow");
            for (slot.list_offsets) |offsets| if (offsets) |v| {
                decoded = std.math.add(usize, decoded, v.len * @sizeOf(usize)) catch @panic("pool size overflow");
            };
            result.decoded_bytes = std.math.add(usize, result.decoded_bytes, decoded) catch @panic("pool size overflow");
            if (slot.state == .leased) {
                result.leased_bytes = std.math.add(usize, result.leased_bytes, slot.allocatedBytes()) catch @panic("pool size overflow");
            } else {
                result.retained_bytes = std.math.add(usize, result.retained_bytes, slot.allocatedBytes()) catch @panic("pool size overflow");
            }
        }
        return result;
    }
    fn ensureAvailableSlot(self: *Pool) error{OutOfMemory}!void {
        for (self.slots) |slot| if (slot.state == .available) return;
        const old_len = self.slots.len;
        const new_len = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
        self.slots = self.allocator.realloc(self.slots, new_len) catch return error.OutOfMemory;
        for (self.slots[old_len..]) |*slot| slot.* = .{};
    }

    fn select(self: *Pool, layout: *const layout_mod.ElementLayout, n: usize) error{ SizeOverflow, BatchCapacityUnavailable, OutOfMemory }!usize {
        try self.ensureAvailableSlot();
        var candidate: ?usize = null;
        var exhausted_generation = false;
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .available) {
                if (slot.generation == std.math.maxInt(u64)) {
                    exhausted_generation = true;
                    continue;
                }
                if (candidate == null) candidate = i;
                if (slot.compatible(layout, n)) {
                    candidate = i;
                    break;
                }
            }
        }
        return candidate orelse if (exhausted_generation) error.SizeOverflow else error.BatchCapacityUnavailable;
    }
    /// Exact new allocator-requested bytes needed for the slot selected by
    /// `acquireWithAllocator`, excluding existing retained allocations.
    pub fn estimateAdditional(self: *Pool, layout: *const layout_mod.ElementLayout, n: usize) error{ SizeOverflow, BatchCapacityUnavailable, InvalidLayout, OutOfMemory }!usize {
        const id = try self.select(layout, n);
        if (self.slots[id].compatible(layout, n)) return 0;
        var has_lists = false;
        for (layout.properties) |prop| {
            if (prop.scalar_type == null) has_lists = true;
        }
        const desc_width: usize = @sizeOf(Owned) + @sizeOf(column_mod.Column) + (if (has_lists) @sizeOf(?[]usize) else @as(usize, 0));
        const descriptors = std.math.mul(usize, layout.properties.len, desc_width) catch return error.SizeOverflow;
        var total = descriptors;
        for (layout.properties) |property| {
            const bytes = if (property.scalar_type) |scalar| std.math.mul(usize, n, scalar.byteWidth()) catch return error.SizeOverflow else std.math.mul(usize, n + 1, @sizeOf(usize)) catch return error.SizeOverflow;
            total = std.math.add(usize, total, bytes) catch return error.SizeOverflow;
        }
        return total;
    }
    pub fn acquire(self: *Pool, layout: *const layout_mod.ElementLayout, n: usize) !usize {
        return self.acquireWithAllocator(layout, n, self.allocator);
    }
    /// `allocator` must share the pool's underlying allocator and accounting.
    pub fn acquireWithAllocator(self: *Pool, layout: *const layout_mod.ElementLayout, n: usize, allocator: std.mem.Allocator) !usize {
        const id = try self.select(layout, n);
        const slot = &self.slots[id];
        slot.state = .filling;
        errdefer slot.state = .available;
        try slot.prepare(allocator, layout, n, null, null);
        return id;
    }

    /// ASCII-only admission: uses the property schema to prepare list offsets.
    pub fn acquireAscii(self: *Pool, layout: *const layout_mod.ElementLayout, props: []const property_mod.Property, n: usize, allocator: std.mem.Allocator) !usize {
        const id = try self.select(layout, n);
        const slot = &self.slots[id];
        slot.state = .filling;
        errdefer slot.state = .available;
        try slot.prepare(allocator, layout, n, props, null);
        return id;
    }

    /// Phase 9 admission prepares list values before submitting the worker.
    /// The decoder must never allocate or grow these buffers concurrently.
    pub fn acquireAsciiSized(self: *Pool, layout: *const layout_mod.ElementLayout, props: []const property_mod.Property, count: usize, totals: []const usize) !usize {
        const id = try self.select(layout, count);
        const slot = &self.slots[id];
        slot.state = .filling;
        errdefer slot.state = .available;
        try slot.prepare(self.allocator, layout, count, props, totals);
        return id;
    }

    /// Phase 10: prepare binary variable-width scalar/list columns with exact
    /// per-property list capacities. No decode-time allocation is necessary.
    pub fn acquireBinaryVariableSized(
        self: *Pool,
        layout: *const layout_mod.ElementLayout,
        props: []const property_mod.Property,
        n: usize,
        totals: []const usize,
    ) !usize {
        _ = try binary_preflight.decodedBytes(layout, n, totals);
        if (props.len != layout.properties.len) return error.InvalidLayout;
        for (props, layout.properties) |prop, compiled| {
            const op = compiled.binary_op orelse return error.InvalidLayout;
            switch (op) {
                .scalar => |s| switch (prop.kind) {
                    .scalar => |type_tag| {
                        if (type_tag != s.scalar_type) return error.InvalidLayout;
                    },
                    else => return error.InvalidLayout,
                },
                .list => |l| switch (prop.kind) {
                    .list => |li| {
                        if (li.count_type != l.count_type or li.item_type != l.item_type) return error.InvalidLayout;
                    },
                    else => return error.InvalidLayout,
                },
            }
        }
        const id = try self.select(layout, n);
        const slot = &self.slots[id];
        slot.state = .filling;
        errdefer slot.state = .available;
        try slot.prepare(self.allocator, layout, n, props, totals);
        return id;
    }

    /// Under pressure, cached output storage must not prevent admitting raw
    /// ASCII text or record-boundary copies. Only idle slots are evicted;
    /// filling, ready and consumer-leased batches remain untouched.
    pub fn reclaimAvailable(self: *Pool) usize {
        var reclaimed: usize = 0;
        for (self.slots) |*slot| {
            if (slot.state != .available) continue;
            const bytes = slot.allocatedBytes();
            if (bytes == 0) continue;
            reclaimed = std.math.add(usize, reclaimed, bytes) catch @panic("reclaimed size overflow");
            slot.clear(self.allocator);
        }
        return reclaimed;
    }

    pub fn reclaimIncompatibleAsciiSized(self: *Pool, layout: *const layout_mod.ElementLayout, props: []const property_mod.Property, n: usize, counts: []const usize) usize {
        var reclaimed: usize = 0;
        for (self.slots) |*slot| {
            if (slot.state == .available and slot.owned.len != 0 and
                (!slot.compatible(layout, n) or !slot.compatibleAsciiCounts(props, counts)))
            {
                reclaimed = std.math.add(usize, reclaimed, slot.allocatedBytes()) catch @panic("reclaimed size overflow");
                slot.clear(self.allocator);
            }
        }
        return reclaimed;
    }

    pub fn reclaimIncompatibleAscii(self: *Pool, layout: *const layout_mod.ElementLayout, props: []const property_mod.Property, n: usize) usize {
        var reclaimed: usize = 0;
        for (self.slots) |*slot| {
            if (slot.state == .available and slot.owned.len != 0 and
                (!slot.compatible(layout, n) or !slot.compatibleAscii(props)))
            {
                reclaimed += slot.allocatedBytes();
                slot.clear(self.allocator);
            }
        }
        return reclaimed;
    }

    /// Validate a full textual record before mutating output, then decode
    /// into the exclusively owned pool slot. Lists are grown only after a
    /// complete line has been received, so an allocation failure is retryable.
    pub fn decodeAsciiRecord(self: *Pool, id: usize, props: []const property_mod.Property, line: []const u8, row: usize, token_limit: usize, item_limit: usize, failed_property: *?usize, failed_token_offset: *?usize) !void {
        const slot = &self.slots[id];
        std.debug.assert(slot.state == .filling);
        if (props.len != slot.owned.len) return error.InvalidLayout;
        // Pass one: strict validation without changing the output.
        try ascii.record.validateWithOffsets(props, line, token_limit, item_limit, failed_property, failed_token_offset);
        // Pass two: capacity growth is atomic per list; a failure leaves
        // this row unpublished and can be retried using its staged line.
        var scanner = ascii.Tokenizer.init(line, token_limit);
        for (props, 0..) |prop, i| {
            failed_property.* = i;
            failed_token_offset.* = scanner.nextTokenStart();
            switch (prop.kind) {
                .scalar => |t| {
                    const token = (try scanner.next()).?;
                    switch (slot.owned[i]) {
                        inline else => |dest, tag| {
                            if (tag != t or row >= dest.len) return error.InvalidOutputCapacity;
                            dest[row] = try ascii.number.parse(tag.zigType(), token);
                        },
                    }
                    slot.columns[i] = .{ .property_index = i, .values = slot.owned[i].view(row + 1) };
                },
                .list => |li| {
                    const count_token = (try scanner.next()).?;
                    const count = try ascii.number.listCount(li.count_type, count_token);
                    const offsets = slot.list_offsets[i] orelse return error.InvalidLayout;
                    if (row + 1 >= offsets.len) return error.InvalidOutputCapacity;
                    const base = offsets[row];
                    const needed = std.math.add(usize, base, count) catch return error.ListTooLarge;
                    if (slot.owned[i].len() < needed) {
                        if (base == 0) {
                            // Phase 8 list batches contain one record. No
                            // values have been published or committed for
                            // this list, so retaining an old, available
                            // batch's value buffer while allocating its
                            // replacement would create avoidable pressure.
                            // Install a safe empty sentinel *before* the
                            // fallible allocation, so a failed attempt can
                            // be cancelled or retried without a double free.
                            slot.owned[i].free(self.allocator);
                            slot.owned[i] = Owned.empty(li.item_type);
                            slot.owned[i] = try Owned.allocate(self.allocator, li.item_type, needed);
                        } else {
                            // Future multi-record list batches must preserve
                            // already committed values on allocation error.
                            const replacement = try Owned.allocate(self.allocator, li.item_type, needed);
                            switch (replacement) {
                                inline else => |new_values, tag| {
                                    const old = @field(slot.owned[i], @tagName(tag));
                                    @memcpy(new_values[0..base], old[0..base]);
                                },
                            }
                            slot.owned[i].free(self.allocator);
                            slot.owned[i] = replacement;
                        }
                    }
                    for (0..count) |j| {
                        failed_token_offset.* = scanner.nextTokenStart();
                        const item_token = (try scanner.next()).?;
                        switch (slot.owned[i]) {
                            inline else => |dest, tag| {
                                if (tag != li.item_type) return error.InvalidColumnType;
                                dest[base + j] = try ascii.number.parse(tag.zigType(), item_token);
                            },
                        }
                    }
                    offsets[row + 1] = needed;
                    slot.columns[i] = .{
                        .property_index = i,
                        .values = slot.owned[i].view(0),
                        .list = .{ .offsets = offsets[0 .. row + 2], .values = slot.owned[i].view(needed) },
                    };
                },
            }
        }
        failed_property.* = null;
        failed_token_offset.* = null;
    }

    /// Phase 9 worker entry. Input, boundaries, metadata and destinations are
    /// exclusively owned by this task; no reader, allocator, or mutable pool
    /// slot table is accessed by the worker.
    pub fn decodePreparedAscii(
        output: Target,
        props: []const property_mod.Property,
        bytes: []const u8,
        boundaries: []const usize,
        token_limit: usize,
        item_limit: usize,
        cancel_flag: ?*const std.atomic.Value(bool),
        failure: *ascii_preflight.Failure,
    ) !void {
        return decodePreparedAsciiWithHooks(
            output,
            props,
            bytes,
            boundaries,
            token_limit,
            item_limit,
            cancel_flag,
            failure,
            null,
            0,
        );
    }

    /// Test-only scheduling checkpoints for deterministic ASCII cancellation.
    /// Normal calls have no hooks and retain the same decoding semantics.
    pub fn decodePreparedAsciiWithHooks(
        output: Target,
        props: []const property_mod.Property,
        bytes: []const u8,
        boundaries: []const usize,
        token_limit: usize,
        item_limit: usize,
        cancel_flag: ?*const std.atomic.Value(bool),
        failure: *ascii_preflight.Failure,
        hooks: ?*const fault_injection.Hooks,
        sequence: u64,
    ) !void {
        if (output.owned.len != props.len or output.columns.len != props.len or
            boundaries.len == 0 or boundaries[0] != 0 or boundaries[boundaries.len - 1] != bytes.len) return error.InvalidLayout;
        const records = boundaries.len - 1;
        for (0..records) |row| {
            failure.* = .{ .record_index = row };
            if (row % 1024 == 0) {
                if (@import("builtin").is_test and row != 0) {
                    if (hooks) |injection| {
                        if (injection.checkpoint) |callback| callback(injection.context, sequence, row);
                    }
                }
                if (cancel_flag) |flag| {
                    if (flag.load(.acquire)) return error.Cancelled;
                }
            }
            const start = boundaries[row];
            const end = boundaries[row + 1];
            if (start >= end or end > bytes.len) return error.InvalidAsciiRecord;
            const line = try ascii_preflight.stripLineEnding(bytes[start..end]);
            var scanner = ascii.Tokenizer.init(line, token_limit);
            for (props, 0..) |prop, i| {
                failure.property_index = i;
                failure.token_offset = scanner.nextTokenStart();
                switch (prop.kind) {
                    .scalar => |tag| {
                        const token = (try scanner.next()) orelse return error.MissingValue;
                        switch (output.owned[i]) {
                            inline else => |dest, own_tag| {
                                if (own_tag != tag) return error.InvalidColumnType;
                                if (row >= dest.len) return error.InvalidOutputCapacity;
                                dest[row] = try ascii.number.parse(own_tag.zigType(), token);
                            },
                        }
                    },
                    .list => |li| {
                        const count_token = (try scanner.next()) orelse return error.MissingValue;
                        const count = try ascii.number.listCount(li.count_type, count_token);
                        if (count > item_limit) return error.ListTooLarge;
                        if (i >= output.list_offsets.len) return error.InvalidLayout;
                        const offsets = output.list_offsets[i] orelse return error.InvalidLayout;
                        if (row + 1 >= offsets.len) return error.InvalidOutputCapacity;
                        const base = offsets[row];
                        const need = std.math.add(usize, base, count) catch return error.SizeOverflow;
                        if (need > output.owned[i].len()) return error.InvalidOutputCapacity;
                        for (0..count) |j| {
                            if (j % 4096 == 0) {
                                if (@import("builtin").is_test and j != 0) {
                                    if (hooks) |injection| {
                                        if (injection.list_item_checkpoint) |callback| callback(injection.context, sequence, j);
                                    }
                                }
                                if (cancel_flag) |flag| {
                                    if (flag.load(.acquire)) return error.Cancelled;
                                }
                            }
                            failure.token_offset = scanner.nextTokenStart();
                            const token = (try scanner.next()) orelse return error.MissingValue;
                            switch (output.owned[i]) {
                                inline else => |dest, own_tag| {
                                    if (own_tag != li.item_type) return error.InvalidColumnType;
                                    dest[base + j] = try ascii.number.parse(own_tag.zigType(), token);
                                },
                            }
                        }
                        offsets[row + 1] = need;
                    },
                }
            }
            failure.property_index = null;
            failure.token_offset = scanner.nextTokenStart();
            if (scanner.hasRemaining()) return error.UnexpectedValue;
        }
        for (props, output.owned, 0..) |prop, own, i| {
            switch (prop.kind) {
                .scalar => output.columns[i] = .{ .property_index = i, .values = own.view(records) },
                .list => {
                    const offsets = output.list_offsets[i] orelse return error.InvalidLayout;
                    output.columns[i] = .{
                        .property_index = i,
                        .values = own.view(0),
                        .list = .{ .offsets = offsets[0 .. records + 1], .values = own.view(offsets[records]) },
                    };
                },
            }
        }
    }

    /// Releases only available slots whose schema/capacity cannot serve the
    /// requested operation. Leased and filling slots are never touched.
    /// Returns the number of evicted slots.
    pub fn reclaimIncompatible(self: *Pool, layout: *const layout_mod.ElementLayout, n: usize) usize {
        var reclaimed: usize = 0;
        for (self.slots) |*slot| {
            if (slot.state == .available and !slot.compatible(layout, n) and slot.owned.len != 0) {
                reclaimed = std.math.add(usize, reclaimed, slot.allocatedBytes()) catch @panic("reclaimed size overflow");
                slot.clear(self.allocator);
            }
        }
        return reclaimed;
    }
    pub fn cancel(self: *Pool, id: usize) void {
        std.debug.assert(self.slots[id].state == .filling);
        self.slots[id].state = .available;
    }
    pub fn preflight(self: *Pool, id: usize, layout: *const layout_mod.ElementLayout, byte_count: usize, n: usize) !void {
        const slot = &self.slots[id];
        const width = layout.fixed_record_size orelse return error.InvalidLayout;
        const total = std.math.mul(usize, width, n) catch return error.SizeOverflow;
        if (total != byte_count or slot.owned.len != layout.properties.len) return error.InvalidLayout;
        for (layout.properties, slot.owned) |prop, own| {
            const t = prop.scalar_type orelse return error.InvalidLayout;
            const off = prop.fixed_offset orelse return error.InvalidLayout;
            const w = prop.fixed_width orelse return error.InvalidLayout;
            if (w != t.byteWidth() or off > width or w > width - off) return error.InvalidLayout;
            if (@as(types.ScalarType, own) != t) return error.InvalidColumnType;
            if (own.len() < n) return error.InvalidOutputCapacity;
        }
    }
    pub fn decode(self: *Pool, id: usize, layout: *const layout_mod.ElementLayout, endian: std.builtin.Endian, bytes: []const u8, n: usize) !void {
        return self.decodeCancelable(id, layout, endian, bytes, n, null);
    }
    pub fn decodeCancelable(
        self: *Pool,
        id: usize,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        bytes: []const u8,
        n: usize,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !void {
        try self.preflight(id, layout, bytes.len, n);
        return decodePrepared(self.target(id), layout, endian, bytes, n, cancel_flag);
    }

    /// Decode against a captured set of column allocations. The owning
    /// Pool's slot table may grow while this function executes; the actual
    /// column allocations must remain exclusively owned by this task.
    pub fn decodePrepared(
        target_value: Target,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        bytes: []const u8,
        n: usize,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !void {
        return decodePreparedWithHooks(target_value, layout, endian, bytes, n, cancel_flag, null, 0);
    }

    /// Test-only checkpoints are observed between complete record blocks.
    /// The normal decodePrepared API remains unchanged; a null hook has no
    /// synchronization or per-record callback overhead.
    pub fn decodePreparedWithHooks(
        target_value: Target,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        bytes: []const u8,
        n: usize,
        cancel_flag: ?*const std.atomic.Value(bool),
        hooks: ?*const fault_injection.Hooks,
        sequence: u64,
    ) !void {
        const width = layout.fixed_record_size orelse return error.InvalidLayout;
        if (target_value.owned.len != layout.properties.len or target_value.columns.len != layout.properties.len) return error.InvalidLayout;
        if ((std.math.mul(usize, width, n) catch return error.SizeOverflow) != bytes.len) return error.InvalidLayout;
        for (layout.properties, target_value.owned) |prop, own| {
            const t = prop.scalar_type orelse return error.InvalidLayout;
            const off = prop.fixed_offset orelse return error.InvalidLayout;
            const w = prop.fixed_width orelse return error.InvalidLayout;
            if (w != t.byteWidth() or off > width or w > width - off) return error.InvalidLayout;
            if (@as(types.ScalarType, own) != t) return error.InvalidColumnType;
            if (own.len() < n) return error.InvalidOutputCapacity;
        }
        // Zero-property elements have logical records but no payload work.
        if (layout.properties.len == 0) return;
        for (0..n) |i| {
            if (i % 4096 == 0) {
                if (@import("builtin").is_test and i != 0) {
                    if (hooks) |injection| {
                        if (injection.checkpoint) |callback| callback(injection.context, sequence, i);
                    }
                }
                if (cancel_flag) |flag| {
                    if (flag.load(.acquire)) return error.Cancelled;
                }
            }
            const record = bytes[i * width ..][0..width];
            for (layout.properties, target_value.owned) |prop, own| {
                const src = record[prop.fixed_offset.?..];
                switch (own) {
                    inline else => |dest, tag| dest[i] = binary.decodeScalarAs(tag.zigType(), endian, src) catch unreachable,
                }
            }
        }
        for (layout.properties, target_value.owned, 0..) |prop, own, i| {
            target_value.columns[i] = .{ .property_index = prop.property_index, .values = own.view(n) };
        }
    }
    /// Phase 10 worker kernel. All destinations must already be allocated.
    /// Never dereferences the original Reader, pool slot table, or allocator.
    /// On failure, output stays in the unpublished filling slot.
    pub fn decodePreparedBinaryVariable(
        output: Target,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        bytes: []const u8,
        offsets: []const usize,
        list_totals: []const usize,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !void {
        return decodePreparedBinaryVariableWithHooks(
            output,
            layout,
            endian,
            bytes,
            offsets,
            list_totals,
            cancel_flag,
            null,
            0,
        );
    }

    /// Optional internal test checkpoints in a long binary list. Production
    /// builds compile out the hooks; the ordinary worker API remains intact.
    pub fn decodePreparedBinaryVariableWithHooks(
        output: Target,
        layout: *const layout_mod.ElementLayout,
        endian: std.builtin.Endian,
        bytes: []const u8,
        offsets: []const usize,
        list_totals: []const usize,
        cancel_flag: ?*const std.atomic.Value(bool),
        hooks: ?*const fault_injection.Hooks,
        sequence: u64,
    ) !void {
        if (offsets.len < 2 or offsets[0] != 0 or offsets[offsets.len - 1] != bytes.len)
            return error.InvalidRecordBoundary;
        const n = offsets.len - 1;
        _ = try binary_preflight.decodedBytes(layout, n, list_totals);
        if (layout.properties.len != output.owned.len or
            layout.properties.len != output.columns.len or
            output.list_offsets.len != layout.properties.len) return error.InvalidLayout;

        // Validate every destination before changing even the first offset.
        for (layout.properties, output.owned, 0..) |prop, owned, i| {
            const op = prop.binary_op orelse return error.InvalidLayout;
            switch (op) {
                .scalar => |s| {
                    if (@as(types.ScalarType, owned) != s.scalar_type or owned.len() < n or
                        output.list_offsets[i] != null) return error.InvalidOutputCapacity;
                },
                .list => |li| {
                    const offs = output.list_offsets[i] orelse return error.InvalidOutputCapacity;
                    if (offs.len < n + 1 or @as(types.ScalarType, owned) != li.item_type or
                        owned.len() < list_totals[i]) return error.InvalidOutputCapacity;
                },
            }
        }
        // Complete the entire output preflight before writing to any caller-
        // supplied column. A later invalid destination must not alter the
        // first list's offset[0], even when the caller retries with a fixed
        // target after an InvalidOutputCapacity result.
        for (layout.properties, output.list_offsets) |prop, maybe_offsets| {
            switch (prop.binary_op.?) {
                .scalar => {},
                .list => maybe_offsets.?[0] = 0,
            }
        }

        for (0..n) |row| {
            if (row % 1024 == 0) {
                if (cancel_flag) |flag| {
                    if (flag.load(.acquire)) return error.Cancelled;
                }
            }
            const first = offsets[row];
            const last = offsets[row + 1];
            if (first >= last or last > bytes.len) return error.InvalidRecordBoundary;
            const record = bytes[first..last];
            var cursor: usize = 0;
            for (layout.properties, output.owned, 0..) |prop, own, i| {
                const op = prop.binary_op orelse return error.InvalidLayout;
                switch (op) {
                    .scalar => |s| {
                        if (s.width > record.len - cursor) return error.InvalidRecordBoundary;
                        switch (own) {
                            inline else => |dest, tag| {
                                if (tag != s.scalar_type) return error.InvalidColumnType;
                                dest[row] = binary.decodeScalarAs(tag.zigType(), endian, record[cursor..]) catch return error.InvalidRecordBoundary;
                            },
                        }
                        cursor += s.width;
                    },
                    .list => |li| {
                        if (li.count_width > record.len - cursor) return error.InvalidRecordBoundary;
                        const count = binary_counts.decodeListCount(li.count_type, endian, record[cursor..]) catch |err| switch (err) {
                            error.NegativeListCount => return error.NegativeListCount,
                            error.CountOverflow => return error.CountOverflow,
                            error.InsufficientBytes => return error.InvalidRecordBoundary,
                        };
                        cursor += li.count_width;
                        const payload = std.math.mul(usize, count, li.item_width) catch return error.SizeOverflow;
                        if (payload > record.len - cursor) return error.InvalidRecordBoundary;
                        const offs = output.list_offsets[i] orelse return error.InvalidOutputCapacity;
                        const base = offs[row];
                        const finish = std.math.add(usize, base, count) catch return error.SizeOverflow;
                        if (finish > list_totals[i] or finish > own.len()) return error.InvalidOutputCapacity;
                        switch (own) {
                            inline else => |dest, tag| {
                                if (tag != li.item_type) return error.InvalidColumnType;
                                for (0..count) |j| {
                                    if (j % 4096 == 0) {
                                        if (@import("builtin").is_test and j != 0) {
                                            if (hooks) |injection| {
                                                if (injection.list_item_checkpoint) |callback|
                                                    callback(injection.context, sequence, j);
                                            }
                                        }
                                        if (cancel_flag) |flag| {
                                            if (flag.load(.acquire)) return error.Cancelled;
                                        }
                                    }
                                    const position = cursor + j * li.item_width;
                                    dest[base + j] = binary.decodeScalarAs(tag.zigType(), endian, record[position..]) catch return error.InvalidRecordBoundary;
                                }
                            },
                        }
                        cursor += payload;
                        offs[row + 1] = finish;
                    },
                }
            }
            if (cursor != record.len) return error.InvalidRecordBoundary;
        }
        if (cancel_flag) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
        }
        for (layout.properties, output.owned, 0..) |prop, own, i| {
            const op = prop.binary_op.?;
            switch (op) {
                .scalar => output.columns[i] = .{
                    .property_index = prop.property_index,
                    .values = own.view(n),
                },
                .list => {
                    const offs = output.list_offsets[i].?;
                    if (offs[n] != list_totals[i]) return error.InvalidOutputCapacity;
                    output.columns[i] = .{
                        .property_index = prop.property_index,
                        .values = own.view(0),
                        .list = .{ .offsets = offs[0 .. n + 1], .values = own.view(offs[n]) },
                    };
                },
            }
        }
    }

    /// Property-major alternative for internal benchmarking; the parser
    /// uses `decode`'s record-major traversal.
    pub fn decodePropertyMajor(self: *Pool, id: usize, layout: *const layout_mod.ElementLayout, endian: std.builtin.Endian, bytes: []const u8, n: usize) !void {
        try self.preflight(id, layout, bytes.len, n);
        const slot = &self.slots[id];
        const width = layout.fixed_record_size.?;
        for (layout.properties, slot.owned, 0..) |prop, own, pi| {
            const offset = prop.fixed_offset.?;
            switch (own) {
                inline else => |dest, tag| {
                    for (0..n) |i| {
                        dest[i] = binary.decodeScalarAs(tag.zigType(), endian, bytes[i * width + offset ..]) catch unreachable;
                    }
                },
            }
            slot.columns[pi] = .{ .property_index = prop.property_index, .values = own.view(n) };
        }
    }
    pub fn publish(self: *Pool, id: usize, info: BatchInfo) Batch {
        self.publishReady(id, info);
        return self.leaseReady(id);
    }
    pub fn publishReady(self: *Pool, id: usize, info: BatchInfo) void {
        const slot = &self.slots[id];
        std.debug.assert(slot.state == .filling);
        // `acquire` checks this before the reader advances.
        slot.generation += 1;
        slot.info = info;
        slot.state = .ready;
    }
    pub fn leaseReady(self: *Pool, id: usize) Batch {
        const slot = &self.slots[id];
        std.debug.assert(slot.state == .ready);
        slot.state = .leased;
        return .{ .pool = self, .slot_id = id, .generation = slot.generation };
    }
};

/// A lease on pool-owned columns. Do not copy as an ownership operation.
/// All leases must be released before the parser is deinitialized.
pub const Batch = struct {
    pool: *anyopaque,
    slot_id: usize,
    generation: u64,

    fn getPool(self: *const Batch) *Pool {
        return @ptrCast(@alignCast(self.pool));
    }
    /// Only valid while the parser and its pool are alive.
    pub fn isValid(self: *const Batch) bool {
        const s = &self.getPool().slots[self.slot_id];
        return s.state == .leased and s.generation == self.generation;
    }
    fn slot(self: *const Batch) *const Slot {
        const s = &self.getPool().slots[self.slot_id];
        if (!self.isValid()) @panic("invalid or released batch lease");
        return s;
    }
    pub fn info(self: *const Batch) BatchInfo {
        return self.slot().info;
    }
    pub fn columnCount(self: *const Batch) usize {
        return self.slot().columns.len;
    }
    pub fn column(self: *const Batch, index: usize) ?column_mod.Column {
        const cols = self.slot().columns;
        return if (index < cols.len) cols[index] else null;
    }
    pub fn columnByPropertyIndex(self: *const Batch, index: usize) ?column_mod.Column {
        for (self.slot().columns) |c| if (c.property_index == index) {
            return c;
        };
        return null;
    }
    pub fn columnByName(self: *const Batch, header: *const header_mod.Header, name: []const u8) ?column_mod.Column {
        const element = header.elements[self.info().element_index];
        for (element.properties, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) return self.columnByPropertyIndex(i);
        }
        return null;
    }
    pub fn typedColumn(self: *const Batch, comptime T: type, index: usize) error{ InvalidColumnType, InvalidPropertyIndex }![]const T {
        const c = self.columnByPropertyIndex(index) orelse return error.InvalidPropertyIndex;
        const tag = comptime blk: {
            for (std.enums.values(types.ScalarType)) |t| {
                if (t.zigType() == T) break :blk t;
            }
            @compileError("not a PLY scalar type");
        };
        if (c.list != null or c.values.scalarType() != tag) return error.InvalidColumnType;
        return @field(c.values, @tagName(tag));
    }
    pub fn listColumn(self: *const Batch, index: usize) error{ InvalidColumnType, InvalidPropertyIndex }!column_mod.ListColumn {
        const c = self.columnByPropertyIndex(index) orelse return error.InvalidPropertyIndex;
        return c.list orelse error.InvalidColumnType;
    }
    pub fn f64Column(self: *const Batch, index: usize) error{ InvalidColumnType, InvalidPropertyIndex }![]const f64 {
        return self.typedColumn(f64, index);
    }
    /// Returns an error rather than panicking for a copied or released
    /// handle. The parser and pool must still be alive.
    pub fn tryRelease(self: *Batch) error{InvalidBatchLease}!void {
        if (!self.isValid()) return error.InvalidBatchLease;
        self.getPool().slots[self.slot_id].state = .available;
        self.generation = 0;
    }
    pub fn release(self: *Batch) void {
        self.tryRelease() catch @panic("invalid or released batch lease");
    }
};

test "preflight rejects invalid input and output before modifying columns" {
    const props = [_]layout_mod.PropertyLayout{.{
        .property_index = 0,
        .fixed_offset = 0,
        .fixed_width = 4,
        .scalar_type = .u32,
    }};
    var layout: layout_mod.ElementLayout = .{
        .element_index = 0,
        .fixed_record_size = 4,
        .minimum_record_size = 4,
        .body_start_offset = null,
        .fixed_body_size = null,
        .properties = &props,
    };
    const pool = try Pool.create(std.testing.allocator);
    defer pool.destroy();
    const id = try pool.acquire(&layout, 1);
    defer pool.cancel(id);
    pool.slots[id].owned[0].u32[0] = 0xfeedbeef;

    try std.testing.expectError(error.InvalidLayout, pool.decode(id, &layout, .little, &.{ 1, 2, 3 }, 1));
    try std.testing.expectError(error.InvalidOutputCapacity, pool.preflight(id, &layout, 8, 2));
    var wrong = props;
    wrong[0].scalar_type = .f32;
    layout.properties = &wrong;
    try std.testing.expectError(error.InvalidColumnType, pool.preflight(id, &layout, 4, 1));
    wrong[0].fixed_offset = 2;
    try std.testing.expectError(error.InvalidLayout, pool.preflight(id, &layout, 4, 1));
    try std.testing.expectEqual(@as(u32, 0xfeedbeef), pool.slots[id].owned[0].u32[0]);
}

test "idle output reclamation never invalidates leased batches" {
    const props = [_]layout_mod.PropertyLayout{.{
        .property_index = 0,
        .fixed_offset = 0,
        .fixed_width = 4,
        .scalar_type = .u32,
    }};
    const layout: layout_mod.ElementLayout = .{
        .element_index = 0,
        .fixed_record_size = 4,
        .minimum_record_size = 4,
        .body_start_offset = null,
        .fixed_body_size = null,
        .properties = &props,
    };
    const pool = try Pool.create(std.testing.allocator);
    defer pool.destroy();

    const first = try pool.acquire(&layout, 16);
    pool.publishReady(first, .{ .element_index = 0, .first_record = 0, .record_count = 16, .sequence = 0 });
    var leased = pool.leaseReady(first);
    defer if (leased.isValid()) leased.release();

    const second = try pool.acquire(&layout, 8);
    pool.cancel(second);
    try std.testing.expect(pool.slots[first].allocatedBytes() > 0);
    try std.testing.expect(pool.slots[second].allocatedBytes() > 0);
    try std.testing.expect(pool.reclaimAvailable() > 0);
    try std.testing.expect(leased.isValid());
    try std.testing.expect(pool.slots[first].allocatedBytes() > 0);
    try std.testing.expectEqual(@as(usize, 0), pool.slots[second].allocatedBytes());

    leased.release();
    try std.testing.expect(pool.reclaimAvailable() > 0);
    try std.testing.expectEqual(@as(usize, 0), pool.slots[first].allocatedBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.reclaimAvailable());
}
