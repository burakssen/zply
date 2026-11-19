//! Stable bootstrap ownership for the parser's budget and allocator.
const std = @import("std");
const budget_mod = @import("budget.zig");
const allocator_mod = @import("allocator.zig");

pub const Control = struct {
    parent: std.mem.Allocator,
    budget: budget_mod.MemoryBudget,
    wrapper: allocator_mod.BudgetAllocator,

    pub fn create(parent: std.mem.Allocator, limit: usize) error{ OutOfMemory, ResourceLimitExceeded }!*Control {
        if (limit < @sizeOf(Control)) return error.ResourceLimitExceeded;
        const self = try parent.create(Control);
        self.parent = parent;
        self.budget = .init(limit);
        self.wrapper = .{ .parent = parent, .budget = &self.budget };
        // The bootstrap allocation was made using the parent because the
        // wrapper did not exist yet. Charge its exact requested size.
        var bootstrap = self.budget.reserve(@sizeOf(Control)) catch unreachable;
        bootstrap.commit(@sizeOf(Control)) catch unreachable;
        self.budget.noteAllocation();
        return self;
    }

    pub fn destroy(self: *Control) void {
        const stats = self.budget.snapshot();
        if (stats.reserved_bytes != 0 or stats.live_bytes != @sizeOf(Control)) {
            @panic("parser memory accounting not empty at destruction");
        }
        const parent = self.parent;
        self.budget.release(@sizeOf(Control));
        self.budget.noteFree();
        parent.destroy(self);
    }
};
