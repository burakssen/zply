//! Stable generation-checked task slots.
const std = @import("std");
const task_mod = @import("task.zig");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    activity: task_mod.Activity = .{},

    pub const Slot = struct {
        active: bool = false,
        generation: u64 = 0,
        task: task_mod.DecodeTask = undefined,
    };
    pub const Lease = struct { id: usize, generation: u64 };

    pub fn init(allocator: std.mem.Allocator, initial: usize) !Registry {
        const slots = try allocator.alloc(Slot, @max(initial, 1));
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .slots = slots };
    }
    pub fn deinit(self: *Registry) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }
    /// The registry is fixed-capacity. Reallocation would move submitted
    /// task descriptors while futures still hold pointers to them.
    pub fn acquire(self: *Registry, task: task_mod.DecodeTask) error{TaskRegistryFull}!Lease {
        for (self.slots, 0..) |*slot, i| {
            if (!slot.active and slot.generation != std.math.maxInt(u64)) {
                slot.active = true;
                slot.generation += 1;
                slot.task = task;
                return .{ .id = i, .generation = slot.generation };
            }
        }
        return error.TaskRegistryFull;
    }
    pub fn get(self: *Registry, id: usize, generation: u64) error{InvalidTaskSlot}!*task_mod.DecodeTask {
        if (id >= self.slots.len) return error.InvalidTaskSlot;
        const slot = &self.slots[id];
        if (!slot.active or slot.generation != generation) return error.InvalidTaskSlot;
        return &slot.task;
    }
    pub fn release(self: *Registry, id: usize, generation: u64) error{InvalidTaskSlot}!void {
        const slot = &(try self.get(id, generation)).*;
        slot.state = .reclaimed;
        self.slots[id].active = false;
    }
    pub fn activeCount(self: *const Registry) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }
};
