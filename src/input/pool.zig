//! Independent raw-buffer ownership for in-flight decode tasks.
const std = @import("std");

pub const State = enum { available, filling, submitted };

pub const Slot = struct {
    storage: []u8 = &.{},
    state: State = .available,
    generation: u64 = 0,
    length: usize = 0,

    pub fn capacity(self: *const Slot) usize {
        return self.storage.len;
    }
    pub fn valid(self: *const Slot) []const u8 {
        return self.storage[0..self.length];
    }
    fn clear(self: *Slot, allocator: std.mem.Allocator) void {
        if (self.storage.len != 0) allocator.free(self.storage);
        self.* = .{};
    }
};

pub const RawLease = struct { id: usize, generation: u64 };

pub const RawBufferPool = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,

    pub fn init(allocator: std.mem.Allocator, initial_slots: usize) !RawBufferPool {
        const slots = try allocator.alloc(Slot, @max(initial_slots, 1));
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .slots = slots };
    }
    pub fn deinit(self: *RawBufferPool) void {
        for (self.slots) |*slot| slot.clear(self.allocator);
        self.allocator.free(self.slots);
        self.* = undefined;
    }
    fn growWithAllocator(self: *RawBufferPool, allocator: std.mem.Allocator) !void {
        const old_len = self.slots.len;
        const new_len = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
        self.slots = try allocator.realloc(self.slots, new_len);
        for (self.slots[old_len..]) |*slot| slot.* = .{};
    }
    /// Prefer a buffer that already fits, avoiding unnecessary growth even
    /// if another available slot happens to appear earlier in the table.
    fn availableSlot(self: *const RawBufferPool, needed: usize) ?usize {
        var first: ?usize = null;
        var best: ?usize = null;
        for (self.slots, 0..) |slot, i| {
            if (slot.state != .available) continue;
            if (first == null) first = i;
            if (slot.storage.len >= needed and
                (best == null or slot.storage.len < self.slots[best.?].storage.len)) best = i;
        }
        return best orelse first;
    }
    pub fn acquire(self: *RawBufferPool, needed: usize) !usize {
        return self.acquireWithAllocator(needed, self.allocator);
    }
    pub fn acquireWithAllocator(self: *RawBufferPool, needed: usize, allocator: std.mem.Allocator) !usize {
        while (true) {
            if (self.availableSlot(needed)) |i| {
                const slot = &self.slots[i];
                slot.state = .filling;
                errdefer slot.state = .available;
                if (slot.storage.len < needed) {
                    slot.storage = try allocator.realloc(slot.storage, needed);
                }
                return i;
            }
            try self.growWithAllocator(allocator);
        }
    }
    /// Additional allocation capacity required for the next acquire. A
    /// failed in-place resize may allocate a new buffer before freeing old
    /// storage, so reserve the full new allocation, not only the delta.
    pub fn estimateAdditional(self: *const RawBufferPool, needed: usize) usize {
        if (self.availableSlot(needed)) |i| {
            return if (self.slots[i].storage.len < needed) needed else 0;
        }
        return needed;
    }

    /// Reclaim only buffers no task can still read. Preserve generations so
    /// an old RawLease can never become valid again after the next publish.
    pub fn reclaimIdle(self: *RawBufferPool) usize {
        var released: usize = 0;
        for (self.slots) |*slot| {
            if (slot.state != .available or slot.storage.len == 0) continue;
            released = std.math.add(usize, released, slot.storage.len) catch @panic("raw capacity overflow");
            const generation = slot.generation;
            slot.clear(self.allocator);
            slot.generation = generation;
        }
        return released;
    }
    pub fn writable(self: *RawBufferPool, id: usize) []u8 {
        std.debug.assert(self.slots[id].state == .filling);
        return self.slots[id].storage;
    }
    pub fn cancel(self: *RawBufferPool, id: usize) error{InvalidRawBuffer}!void {
        if (self.slots[id].state != .filling) return error.InvalidRawBuffer;
        self.slots[id].state = .available;
        self.slots[id].length = 0;
    }
    pub fn capacityBytes(self: *const RawBufferPool) usize {
        var total: usize = 0;
        for (self.slots) |slot| total = std.math.add(usize, total, slot.storage.len) catch @panic("raw pool size overflow");
        return total;
    }
    pub fn publish(self: *RawBufferPool, id: usize, length: usize) RawLease {
        const slot = &self.slots[id];
        std.debug.assert(slot.state == .filling and length <= slot.storage.len);
        slot.length = length;
        slot.state = .submitted;
        slot.generation += 1;
        return .{ .id = id, .generation = slot.generation };
    }
    pub fn get(self: *RawBufferPool, id: usize, generation: u64) error{InvalidRawBuffer}![]const u8 {
        const slot = &self.slots[id];
        if (slot.state != .submitted or slot.generation != generation) return error.InvalidRawBuffer;
        return slot.valid();
    }
    pub fn release(self: *RawBufferPool, id: usize, generation: u64) error{InvalidRawBuffer}!void {
        const slot = &self.slots[id];
        if (slot.state != .submitted or slot.generation != generation) return error.InvalidRawBuffer;
        slot.state = .available;
        slot.length = 0;
    }
};
