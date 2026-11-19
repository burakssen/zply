//! Operation-scoped allocator funded by one exclusive reservation.
//!
//! Neither this value nor its reservation may move or be used concurrently
//! while an allocator interface referencing it is active. Allocated memory can
//! outlive this value and be freed by the ordinary budget allocator using the
//! same underlying allocator and budget.
const std = @import("std");
const budget_mod = @import("budget.zig");

pub const ReservedAllocator = struct {
    parent: std.mem.Allocator,
    reservation: *budget_mod.Reservation,
    failure: Failure = .none,

    pub const Failure = enum { none, insufficient_reservation, underlying_allocator };

    pub fn allocator(self: *ReservedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                // A realloc through this interface falls back to allocating a
                // fully reserved replacement before freeing its old allocation.
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ReservedAllocator = @ptrCast(@alignCast(ctx));
        self.failure = .none;
        self.reservation.checkCommit(len) catch {
            self.failure = .insufficient_reservation;
            return null;
        };
        const ptr = self.parent.rawAlloc(len, alignment, ra) orelse {
            self.failure = .underlying_allocator;
            return null;
        };
        // No other operation may use this reservation between checkCommit()
        // and commit(). Violating that ownership contract is a programmer
        // error, not a recoverable allocation failure.
        self.reservation.commit(len) catch @panic("invalid reservation ownership");
        return ptr;
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ReservedAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(bytes, alignment, ra);
        self.reservation.budget.release(bytes.len);
    }
};
