const std = @import("std");

pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    pub fn isRequested(self: *const Cancellation) bool {
        return self.requested.load(.acquire);
    }
    pub fn check(self: *const Cancellation) error{Cancelled}!void {
        if (self.isRequested()) return error.Cancelled;
    }
};
