const std = @import("std");
const memory = @import("zply_internals").memory;

test "reservation partial commitment cancellation and stale handles" {
    var budget = memory.MemoryBudget.init(100);
    var r = try budget.reserve(70);
    var copy = r;
    try std.testing.expectEqual(@as(usize, 30), budget.available());
    try r.commit(30);
    var stats = budget.snapshot();
    try std.testing.expectEqual(@as(usize, 30), stats.live_bytes);
    try std.testing.expectEqual(@as(usize, 40), stats.reserved_bytes);
    try std.testing.expectError(error.InvalidReservation, copy.commit(1));
    try std.testing.expectError(error.InvalidAmount, r.commit(41));
    try r.cancel();
    try std.testing.expectError(error.InvalidReservation, copy.cancel());
    var next = try budget.reserve(70);
    try std.testing.expectError(error.InvalidReservation, copy.commit(1));
    try next.commit(70);
    try std.testing.expectError(error.InvalidReservation, next.commit(0));
    try std.testing.expectError(error.MemoryBudgetExceeded, budget.reserve(1));
    budget.release(100);
    stats = budget.snapshot();
    try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
    try std.testing.expectEqual(@as(usize, 100), stats.peak_live_bytes);
    try std.testing.expectEqual(@as(usize, 100), stats.peak_total_bytes);
}

test "random reservation operations always preserve budget invariant" {
    var budget = memory.MemoryBudget.init(4096);
    var prng = std.Random.DefaultPrng.init(0x742812);
    const random = prng.random();
    var live: usize = 0;
    for (0..2000) |_| {
        const n = random.intRangeAtMost(usize, 0, 500);
        if (budget.reserve(n)) |value| {
            var r = value;
            const committed = random.intRangeAtMost(usize, 0, n);
            try r.commit(committed);
            live += committed;
            if (committed < n) try r.cancel();
        } else |err| {
            try std.testing.expectEqual(error.MemoryBudgetExceeded, err);
        }
        if (live != 0 and random.boolean()) {
            const freed = random.intRangeAtMost(usize, 0, live);
            budget.release(freed);
            live -= freed;
        }
        const s = budget.snapshot();
        try std.testing.expect(s.live_bytes <= s.budget_bytes);
        try std.testing.expect(s.reserved_bytes <= s.budget_bytes - s.live_bytes);
        try std.testing.expectEqual(live, s.live_bytes);
    }
    budget.release(live);
    try std.testing.expectEqual(@as(usize, 4096), budget.available());
}

test "budgeted allocator counts retained capacity and failed allocation" {
    var budget = memory.MemoryBudget.init(256);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var wrapper: memory.BudgetAllocator = .{ .parent = failing.allocator(), .budget = &budget };
    const a = wrapper.allocator();
    const data = try a.alloc(u64, 16);
    try std.testing.expectEqual(@as(usize, 128), budget.snapshot().live_bytes);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 129));
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().reserved_bytes);
    a.free(data);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 64));
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().live_bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().reserved_bytes);
}

test "replacement allocation counts old and new capacities simultaneously" {
    var budget = memory.MemoryBudget.init(100);
    var wrapper: memory.BudgetAllocator = .{ .parent = std.testing.allocator, .budget = &budget };
    const a = wrapper.allocator();
    const old = try a.alloc(u8, 60);
    defer a.free(old);
    @memset(old, 0x5a);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 50));
    try std.testing.expectEqual(@as(u8, 0x5a), old[0]);
    try std.testing.expectEqual(@as(usize, 60), budget.snapshot().live_bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().reserved_bytes);
}

test "in-place resize charges growth and releases successful shrink" {
    var backing: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var budget = memory.MemoryBudget.init(100);
    var wrapper: memory.BudgetAllocator = .{ .parent = fixed.allocator(), .budget = &budget };
    const a = wrapper.allocator();
    const initial = try a.alloc(u8, 40);
    try std.testing.expect(a.resize(initial, 80));
    const grown = initial.ptr[0..80];
    try std.testing.expectEqual(@as(usize, 80), budget.snapshot().live_bytes);
    try std.testing.expect(!a.resize(grown, 101));
    try std.testing.expectEqual(@as(usize, 80), budget.snapshot().live_bytes);
    try std.testing.expect(a.resize(grown, 20));
    const shrunk = grown.ptr[0..20];
    try std.testing.expectEqual(@as(usize, 20), budget.snapshot().live_bytes);
    a.free(shrunk);
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().live_bytes);
}

test "realloc accounts for replacement peak and preserves old data on denial" {
    var budget = memory.MemoryBudget.init(100);
    var wrapper: memory.BudgetAllocator = .{ .parent = std.testing.allocator, .budget = &budget };
    const a = wrapper.allocator();
    const original = try a.alloc(u8, 40);
    @memset(original, 0x5a);
    const replacement = try a.realloc(original, 50);
    try std.testing.expectEqual(@as(usize, 50), budget.snapshot().live_bytes);
    try std.testing.expectEqual(@as(usize, 90), budget.snapshot().peak_total_bytes);
    try std.testing.expectEqual(@as(u8, 0x5a), replacement[0]);
    try std.testing.expectError(error.OutOfMemory, a.realloc(replacement, 60));
    try std.testing.expectEqual(@as(u8, 0x5a), replacement[0]);
    try std.testing.expectEqual(@as(usize, 50), budget.snapshot().live_bytes);
    a.free(replacement);
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().live_bytes);
}

test "simultaneous reservations cannot spend the same capacity" {
    const Worker = struct {
        fn run(b: *memory.MemoryBudget) void {
            for (0..10_000) |_| {
                var reservation = b.reserve(8) catch continue;
                reservation.commit(8) catch @panic("reservation unexpectedly invalid");
                b.release(8);
            }
        }
    };
    var budget = memory.MemoryBudget.init(16);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&budget});
    for (threads) |thread| thread.join();
    const stats = budget.snapshot();
    try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
    try std.testing.expect(stats.peak_total_bytes <= stats.budget_bytes);
}

test "one reservation funds multiple allocations without double charging" {
    var budget = memory.MemoryBudget.init(100);
    var reservation = try budget.reserve(80);
    var scoped: memory.ReservedAllocator = .{
        .parent = std.testing.allocator,
        .reservation = &reservation,
    };
    const a = scoped.allocator();
    const first = try a.alloc(u8, 32);
    const second = try a.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 32), try reservation.remaining());
    var stats = budget.snapshot();
    try std.testing.expectEqual(@as(usize, 48), stats.live_bytes);
    try std.testing.expectEqual(@as(usize, 32), stats.reserved_bytes);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 33));
    try std.testing.expectEqual(memory.ReservedAllocator.Failure.insufficient_reservation, scoped.failure);
    a.free(first);
    a.free(second);
    try reservation.cancel();
    stats = budget.snapshot();
    try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
    try std.testing.expectEqual(@as(usize, 80), stats.peak_total_bytes);
}

test "reserved allocation failure leaves reservation available for cleanup" {
    var budget = memory.MemoryBudget.init(100);
    var reservation = try budget.reserve(80);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scoped: memory.ReservedAllocator = .{
        .parent = failing.allocator(),
        .reservation = &reservation,
    };
    try std.testing.expectError(error.OutOfMemory, scoped.allocator().alloc(u8, 32));
    try std.testing.expectEqual(memory.ReservedAllocator.Failure.underlying_allocator, scoped.failure);
    try std.testing.expectEqual(@as(usize, 80), try reservation.remaining());
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().live_bytes);
    try reservation.cancel();
    try std.testing.expectEqual(@as(usize, 0), budget.snapshot().reserved_bytes);
}

test "separate operations cannot consume each other's reservation" {
    var budget = memory.MemoryBudget.init(100);
    var first = try budget.reserve(30);
    var second = try budget.reserve(40);
    var child_a: memory.ReservedAllocator = .{ .parent = std.testing.allocator, .reservation = &first };
    var child_b: memory.ReservedAllocator = .{ .parent = std.testing.allocator, .reservation = &second };
    try std.testing.expectError(error.OutOfMemory, child_a.allocator().alloc(u8, 31));
    try std.testing.expectEqual(@as(usize, 40), try second.remaining());
    const bytes = try child_b.allocator().alloc(u8, 40);
    var normal: memory.BudgetAllocator = .{ .parent = std.testing.allocator, .budget = &budget };
    normal.allocator().free(bytes);
    try first.cancel();
    const stats = budget.snapshot();
    try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
}
