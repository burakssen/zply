//! Independent Phase 7 execution window used by internal unit tests.
//! The public Parser coordinates admission directly so that native futures
//! always reference its stable heap registry and never a movable Parser.
const std = @import("std");
const task_mod = @import("task.zig");
const window_mod = @import("window.zig");

pub const Scheduler = struct {
    io: std.Io,
    window: window_mod.Window = .{},
    earliest_failure: ?task_mod.DecodeTask.TaskFailure = null,

    pub fn init(io: std.Io) Scheduler {
        return .{ .io = io };
    }
    pub fn run(task: *task_mod.DecodeTask) !void {
        try task.execute();
    }
    pub fn submit(self: *Scheduler, task: task_mod.DecodeTask) !void {
        try self.window.submit(self.io, task);
    }
    pub fn poll(self: *Scheduler) anyerror!?task_mod.DecodeTask {
        if (self.window.pending() == 0) return null;
        return try self.window.popNext(self.io);
    }
    pub fn cancel(self: *Scheduler) void {
        self.window.cancelAll(self.io);
    }
    pub fn pollAny(self: *Scheduler) anyerror!?task_mod.DecodeTask {
        if (self.window.pending() == 0) return null;
        return try self.window.popAny(self.io);
    }
    pub fn recordFailure(self: *Scheduler, failure_info: task_mod.DecodeTask.TaskFailure) void {
        if (self.earliest_failure == null or failure_info.sequence < self.earliest_failure.?.sequence) {
            self.earliest_failure = failure_info;
        }
    }
    pub fn failure(self: *const Scheduler) ?task_mod.DecodeTask.TaskFailure {
        return self.earliest_failure;
    }
    pub fn pending(self: *const Scheduler) usize {
        return self.window.pending();
    }
};
