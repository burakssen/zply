//! Synchronized accounting for live and reserved allocation capacity.
//! This controller does not allocate and never holds its lock during I/O or
//! while calling an underlying allocator. It must not be moved while handles
//! to it exist.
const std = @import("std");

pub const MemoryStats = struct {
    budget_bytes: usize,
    live_bytes: usize,
    reserved_bytes: usize,
    peak_live_bytes: usize,
    peak_total_bytes: usize,
    allocation_count: u64,
    resize_count: u64,
    free_count: u64,
    batch_reductions: u64,
    pool_evictions: u64,
    bytes_reclaimed: usize,
    reservation_failures: u64,
    raw_buffer_bytes: usize = 0,
    decoded_buffer_bytes: usize = 0,
    retained_bytes: usize = 0,
    leased_bytes: usize = 0,
};

const Entry = struct {
    generation: u64 = 0,
    remaining: usize = 0,
    active: bool = false,
};

pub const Reservation = struct {
    budget: *MemoryBudget,
    index: usize,
    generation: u64,

    /// Commits a portion to live accounting. A fully committed reservation
    /// is automatically closed; copied or stale handles are rejected.
    pub fn commit(self: *Reservation, bytes: usize) error{ InvalidReservation, InvalidAmount }!void {
        return self.budget.commit(self, bytes);
    }

    /// Cancels all uncommitted bytes. Already committed allocations stay live.
    pub fn cancel(self: *Reservation) error{InvalidReservation}!void {
        return self.budget.cancel(self);
    }

    /// Remaining uncommitted capacity; fully committed or cancelled handles
    /// are invalid. The budget must outlive the reservation.
    pub fn remaining(self: *const Reservation) error{InvalidReservation}!usize {
        return self.budget.remaining(self.*);
    }

    /// Validates a commitment without modifying accounting. The caller must
    /// maintain exclusive ownership until the subsequent commit.
    pub fn checkCommit(self: *const Reservation, bytes: usize) error{ InvalidReservation, InvalidAmount }!void {
        return self.budget.checkCommit(self.*, bytes);
    }
};

pub const MemoryBudget = struct {
    const max_reservations = 64;
    lock_state: std.atomic.Value(u8) = .init(0),
    limit: usize,
    live: usize = 0,
    reserved: usize = 0,
    peak_live: usize = 0,
    peak_total: usize = 0,
    batch_reductions: u64 = 0,
    pool_evictions: u64 = 0,
    bytes_reclaimed: usize = 0,
    reservation_failures: u64 = 0,
    allocation_count: u64 = 0,
    resize_count: u64 = 0,
    free_count: u64 = 0,
    entries: [max_reservations]Entry = @splat(.{}),

    pub fn init(limit: usize) MemoryBudget {
        return .{ .limit = limit };
    }
    fn lock(self: *MemoryBudget) void {
        while (self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *MemoryBudget) void {
        self.lock_state.store(0, .release);
    }
    fn peaks(self: *MemoryBudget) void {
        self.peak_live = @max(self.peak_live, self.live);
        self.peak_total = @max(self.peak_total, self.live + self.reserved);
    }
    fn entry(self: *MemoryBudget, handle: Reservation) ?*Entry {
        if (handle.budget != self or handle.index >= self.entries.len) return null;
        const e = &self.entries[handle.index];
        if (!e.active or e.generation != handle.generation) return null;
        return e;
    }
    pub fn reserve(self: *MemoryBudget, bytes: usize) error{ MemoryBudgetExceeded, ReservationCapacityExceeded }!Reservation {
        self.lock();
        defer self.unlock();
        if (bytes > self.limit - self.live - self.reserved) {
            self.reservation_failures += 1;
            return error.MemoryBudgetExceeded;
        }
        for (&self.entries, 0..) |*e, i| {
            if (e.active or e.generation == std.math.maxInt(u64)) continue;
            e.generation += 1;
            e.remaining = bytes;
            e.active = true;
            self.reserved += bytes;
            self.peaks();
            return .{ .budget = self, .index = i, .generation = e.generation };
        }
        self.reservation_failures += 1;
        return error.ReservationCapacityExceeded;
    }
    fn commit(self: *MemoryBudget, handle: *Reservation, bytes: usize) error{ InvalidReservation, InvalidAmount }!void {
        self.lock();
        defer self.unlock();
        const e = self.entry(handle.*) orelse return error.InvalidReservation;
        if (bytes > e.remaining) return error.InvalidAmount;
        // Rotate the generation on partial progress, invalidating copies
        // made before the commitment. Never wrap a generation.
        if (bytes < e.remaining and e.generation == std.math.maxInt(u64)) return error.InvalidReservation;
        self.reserved -= bytes;
        self.live += bytes;
        e.remaining -= bytes;
        if (e.remaining == 0) {
            e.active = false;
        } else {
            e.generation += 1;
            handle.generation = e.generation;
        }
        self.peaks();
    }
    fn cancel(self: *MemoryBudget, handle: *Reservation) error{InvalidReservation}!void {
        self.lock();
        defer self.unlock();
        const e = self.entry(handle.*) orelse return error.InvalidReservation;
        self.reserved -= e.remaining;
        e.remaining = 0;
        e.active = false;
    }
    fn remaining(self: *MemoryBudget, handle: Reservation) error{InvalidReservation}!usize {
        self.lock();
        defer self.unlock();
        return (self.entry(handle) orelse return error.InvalidReservation).remaining;
    }
    fn checkCommit(self: *MemoryBudget, handle: Reservation, bytes: usize) error{ InvalidReservation, InvalidAmount }!void {
        self.lock();
        defer self.unlock();
        const e = self.entry(handle) orelse return error.InvalidReservation;
        if (bytes > e.remaining) return error.InvalidAmount;
        if (bytes < e.remaining and e.generation == std.math.maxInt(u64)) return error.InvalidReservation;
    }
    /// Called once for each successful free or physical in-place shrink.
    /// The caller must own the allocation whose capacity is released.
    pub fn release(self: *MemoryBudget, bytes: usize) void {
        self.lock();
        defer self.unlock();
        if (bytes > self.live) @panic("memory accounting underflow");
        self.live -= bytes;
    }
    /// Successful allocator operations are separate from byte accounting so
    /// benchmarks can distinguish churn from peak live capacity.
    pub fn noteAllocation(self: *MemoryBudget) void {
        self.lock();
        defer self.unlock();
        self.allocation_count +%= 1;
    }
    pub fn noteResize(self: *MemoryBudget) void {
        self.lock();
        defer self.unlock();
        self.resize_count +%= 1;
    }
    pub fn noteFree(self: *MemoryBudget) void {
        self.lock();
        defer self.unlock();
        self.free_count +%= 1;
    }
    pub fn noteBatchReduction(self: *MemoryBudget) void {
        self.lock();
        defer self.unlock();
        self.batch_reductions += 1;
    }
    pub fn notePoolEviction(self: *MemoryBudget, bytes: usize) void {
        self.lock();
        defer self.unlock();
        self.pool_evictions += 1;
        self.bytes_reclaimed = std.math.add(usize, self.bytes_reclaimed, bytes) catch @panic("memory diagnostic overflow");
    }
    pub fn snapshot(self: *MemoryBudget) MemoryStats {
        self.lock();
        defer self.unlock();
        return .{
            .budget_bytes = self.limit,
            .live_bytes = self.live,
            .reserved_bytes = self.reserved,
            .peak_live_bytes = self.peak_live,
            .peak_total_bytes = self.peak_total,
            .batch_reductions = self.batch_reductions,
            .pool_evictions = self.pool_evictions,
            .bytes_reclaimed = self.bytes_reclaimed,
            .reservation_failures = self.reservation_failures,
            .allocation_count = self.allocation_count,
            .resize_count = self.resize_count,
            .free_count = self.free_count,
        };
    }
    pub fn available(self: *MemoryBudget) usize {
        const s = self.snapshot();
        return s.budget_bytes - s.live_bytes - s.reserved_bytes;
    }
};
