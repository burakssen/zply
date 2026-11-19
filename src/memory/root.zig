//! Internal memory-budget primitives. Parser integration is in progress.
pub const budget = @import("budget.zig");
pub const allocator = @import("allocator.zig");
pub const MemoryBudget = budget.MemoryBudget;
pub const MemoryStats = budget.MemoryStats;
pub const Reservation = budget.Reservation;
pub const BudgetAllocator = allocator.BudgetAllocator;
pub const control = @import("control.zig");
pub const reserved_allocator = @import("reserved_allocator.zig");
pub const ReservedAllocator = reserved_allocator.ReservedAllocator;
