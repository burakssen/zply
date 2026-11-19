//! Accounting allocator. The wrapper and its budget must remain at stable
//! addresses and outlive all allocations made through it.
const std = @import("std");
const MemoryBudget = @import("budget.zig").MemoryBudget;

pub const BudgetAllocator = struct {
    parent: std.mem.Allocator,
    budget: *MemoryBudget,
    // Diagnostic for the current sequential parser operation, not a
    // concurrent per-task error channel.
    last_failure: std.atomic.Value(u8) = .init(0),

    pub fn clearFailure(self: *BudgetAllocator) void {
        self.last_failure.store(0, .monotonic);
    }
    pub fn budgetDenied(self: *BudgetAllocator) bool {
        return self.last_failure.load(.monotonic) == 1;
    }

    pub fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.clearFailure();
        var reservation = self.budget.reserve(len) catch {
            self.last_failure.store(1, .monotonic);
            return null;
        };
        const ptr = self.parent.rawAlloc(len, alignment, ra) orelse {
            reservation.cancel() catch unreachable;
            return null;
        };
        reservation.commit(len) catch unreachable;
        self.budget.noteAllocation();
        return ptr;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) {
            if (!self.parent.rawResize(memory, alignment, new_len, ra)) return false;
            self.budget.release(memory.len - new_len);
            self.budget.noteResize();
            return true;
        }
        const delta = new_len - memory.len;
        self.clearFailure();
        var reservation = self.budget.reserve(delta) catch {
            self.last_failure.store(1, .monotonic);
            return false;
        };
        if (!self.parent.rawResize(memory, alignment, new_len, ra)) {
            reservation.cancel() catch unreachable;
            return false;
        }
        reservation.commit(delta) catch unreachable;
        self.budget.noteResize();
        return true;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Never delegate potentially moving remaps: Allocator.realloc will
        // allocate a separately charged replacement before freeing the old
        // allocation, so the transient peak is accounted.
        return null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
        self.budget.release(memory.len);
        self.budget.noteFree();
    }
};
