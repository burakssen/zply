//! Phase 11 M14: independent backing-allocator accounting, generation-checked
//! batch ownership, retained list storage and recovery under lease pressure.
//! Use only zply_internals: the public and internal modules share source files
//! and cannot be imported together in one Zig 0.17 test compilation.
const std = @import("std");
const internal = @import("zply_internals");
const Parser = internal.parser.Parser;
const Batch = internal.batch_storage.Batch;
const MemoryStats = internal.memory.MemoryStats;

/// Independent allocator-request accounting. Neither parser accounting nor
/// budget reservations are consulted when computing physical live/peak bytes.
/// The parent allocator is the leak-checking std.testing.allocator.
const Meter = struct {
    parent: std.mem.Allocator = std.testing.allocator,
    live: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,

    fn allocator(self: *Meter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        self.allocations += 1;
        return result;
    }
    fn resize(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(old, alignment, new_len, ra)) return false;
        if (new_len > old.len) {
            self.live += new_len - old.len;
            self.peak = @max(self.peak, self.live);
        } else {
            self.live -= old.len - new_len;
        }
        return true;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Force allocating-replacement behavior through Allocator.realloc,
        // so both old and new capacity appear in the backing peak.
        return null;
    }
    fn free(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(old, alignment, ra);
        self.live -= old.len;
        self.frees += 1;
    }
};

fn check(parser: *const Parser, meter: *const Meter) !MemoryStats {
    const s = parser.memoryStats();
    try std.testing.expectEqual(meter.live, s.live_bytes);
    try std.testing.expect(s.live_bytes <= s.budget_bytes);
    try std.testing.expect(s.reserved_bytes <= s.budget_bytes - s.live_bytes);
    try std.testing.expect(s.peak_live_bytes <= s.peak_total_bytes);
    try std.testing.expect(s.peak_total_bytes <= s.budget_bytes);
    try std.testing.expect(meter.peak <= s.peak_total_bytes);
    try std.testing.expect(s.decoded_buffer_bytes <= s.leased_bytes + s.retained_bytes);
    try std.testing.expect(s.leased_bytes + s.retained_bytes <= s.live_bytes);
    // No worker is executing across the synchronous call boundary.
    try std.testing.expectEqual(@as(usize, 0), s.reserved_bytes);
    return s;
}

const small_header = "ply\nformat binary_little_endian 1.0\nelement item 40\nproperty uchar value\nend_header\n";
const small_body: [40]u8 = @splat(19);

test "M14 retained leases survive pool growth and stale copies cannot release reused storage" {
    var meter: Meter = .{};
    var reader: std.Io.Reader = .fixed(small_header ++ small_body);
    var parser = try Parser.init(meter.allocator(), std.testing.io, &reader, .{
        .chunk_size = 1,
        .memory_budget = 128 * 1024,
    });
    defer {
        parser.deinit();
        std.debug.assert(meter.live == 0);
    }

    // Retain enough one-record batches to grow the pool's slot array more
    // than once. Stable handle indices and separately owned columns must
    // survive relocation of that array.
    var held: [12]Batch = undefined;
    var held_count: usize = 0;
    defer {
        for (held[0..held_count]) |*batch| {
            if (batch.isValid()) batch.release();
        }
    }
    for (&held) |*batch| {
        batch.* = (try parser.next()).?;
        held_count += 1;
        try std.testing.expectEqual(@as(u8, 19), (try batch.typedColumn(u8, 0))[0]);
        const s = try check(&parser, &meter);
        try std.testing.expect(s.leased_bytes > 0);
    }
    for (&held, 0..) |*a, i| {
        const av = try a.typedColumn(u8, 0);
        for (held[0..i]) |*b| {
            const bv = try b.typedColumn(u8, 0);
            try std.testing.expect(av.ptr != bv.ptr);
        }
    }

    var stale = held[0];
    const old_slot = stale.slot_id;
    const old_generation = stale.generation;
    held[0].release();
    try std.testing.expect(!stale.isValid());
    try std.testing.expectError(error.InvalidBatchLease, stale.tryRelease());

    // Continue far enough to force reuse of the released slot. A stale copy
    // must never become valid again even if the slot index is recycled.
    var reused = false;
    var delivered: usize = held_count;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        if (batch.slot_id == old_slot) {
            reused = true;
            try std.testing.expect(batch.generation != old_generation);
            try std.testing.expect(!stale.isValid());
            try std.testing.expectError(error.InvalidBatchLease, stale.tryRelease());
        }
        try std.testing.expectEqual(@as(u8, 19), (try batch.typedColumn(u8, 0))[0]);
        for (held[1..held_count]) |*retained| {
            try std.testing.expect(retained.isValid());
            try std.testing.expectEqual(@as(u8, 19), (try retained.typedColumn(u8, 0))[0]);
        }
        delivered += batch.info().record_count;
        _ = try check(&parser, &meter);
    }
    try std.testing.expect(reused);
    try std.testing.expectEqual(@as(usize, 40), delivered);
    for (held[1..held_count]) |*batch| batch.release();
    held_count = 0;
    const s = try check(&parser, &meter);
    try std.testing.expectEqual(@as(usize, 0), s.leased_bytes);
    try std.testing.expect(s.retained_bytes > 0);
}

const list_header = "ply\nformat binary_little_endian 1.0\n" ++
    "element face 2\nproperty list uchar int ids\nproperty uchar tag\n" ++
    "element camera 1\nproperty double value\nend_header\n";
const list_body = [_]u8{
    // Face 0: [5,6], tag 11.
    2, 5, 0, 0, 0, 6, 0, 0, 0, 11,
    // Face 1: [], tag 12.
    0, 12,
    // Camera: f64 1.0.
    0, 0, 0, 0, 0, 0, 0xf0, 0x3f,
};

test "M14 list offsets and typed columns remain stable across element transitions" {
    var meter: Meter = .{};
    var reader: std.Io.Reader = .fixed(list_header ++ list_body);
    var parser = try Parser.init(meter.allocator(), std.testing.io, &reader, .{
        .chunk_size = 10, .memory_budget = 128 * 1024,
    });
    defer {
        parser.deinit();
        std.debug.assert(meter.live == 0);
    }
    var first = (try parser.next()).?;
    defer if (first.isValid()) first.release();
    const a = try first.listColumn(0);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, a.offsets);
    try std.testing.expectEqualSlices(i32, &.{ 5, 6 }, a.row(0).?.i32);
    try std.testing.expectEqual(@as(u8, 11), (try first.typedColumn(u8, 1))[0]);
    _ = try check(&parser, &meter);

    var second = (try parser.next()).?;
    defer if (second.isValid()) second.release();
    const b = try second.listColumn(0);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0 }, b.offsets);
    try std.testing.expectEqual(@as(usize, 0), b.row(0).?.i32.len);
    try std.testing.expectEqual(@as(u8, 12), (try second.typedColumn(u8, 1))[0]);
    var third = (try parser.next()).?;
    defer if (third.isValid()) third.release();
    try std.testing.expectEqual(@as(usize, 1), third.info().element_index);
    try std.testing.expectEqual(@as(f64, 1.0), (try third.typedColumn(f64, 0))[0]);
    try std.testing.expect((try parser.next()) == null);

    // Keeping all three leased makes the original list data immutable.
    try std.testing.expectEqualSlices(i32, &.{ 5, 6 }, (try first.listColumn(0)).row(0).?.i32);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, (try first.listColumn(0)).offsets);
    try std.testing.expectEqual(@as(u8, 11), (try first.typedColumn(u8, 1))[0]);
    const before = try check(&parser, &meter);
    try std.testing.expect(before.leased_bytes > 0);
    first.release();
    second.release();
    third.release();
    const after = try check(&parser, &meter);
    try std.testing.expectEqual(@as(usize, 0), after.leased_bytes);
    try std.testing.expect(after.retained_bytes >= before.leased_bytes);
    try std.testing.expectEqual(before.live_bytes, after.live_bytes);
}

const ascii_header = "ply\nformat ascii 1.0\nelement item 512\nproperty uchar value\nend_header\n";
const binary_le_header = "ply\nformat binary_little_endian 1.0\nelement item 512\nproperty uchar value\nend_header\n";
const binary_be_header = "ply\nformat binary_big_endian 1.0\nelement item 512\nproperty uchar value\nend_header\n";
const ascii_data = blk: {
    var bytes: [1024]u8 = undefined;
    for (0..512) |i| {
        bytes[i * 2] = '7';
        bytes[i * 2 + 1] = '\n';
    }
    break :blk bytes;
};
const binary_data: [512]u8 = @splat(7);

test "M14 independent backing allocation agrees with parser accounting across budgets and encodings" {
    const Encoding = enum { ascii, little, big };
    inline for ([_]Encoding{ .ascii, .little, .big }) |encoding| {
        inline for (.{ 32 * 1024, 128 * 1024, 1024 * 1024 }) |budget| {
            const source: []const u8 = switch (encoding) {
                .ascii => ascii_header ++ ascii_data,
                .little => binary_le_header ++ binary_data,
                .big => binary_be_header ++ binary_data,
            };
            var meter: Meter = .{};
            var reader: std.Io.Reader = .fixed(source);
            var parser = try Parser.init(meter.allocator(), std.testing.io, &reader, .{
                .chunk_size = 64, .memory_budget = budget,
            });
            var count: usize = 0;
            _ = try check(&parser, &meter);
            while (try parser.next()) |value| {
                var batch = value;
                defer batch.release();
                const values = try batch.typedColumn(u8, 0);
                try std.testing.expectEqual(batch.info().record_count, values.len);
                for (values) |n| try std.testing.expectEqual(@as(u8, 7), n);
                count += values.len;
                _ = try check(&parser, &meter);
            }
            try std.testing.expectEqual(@as(usize, 512), count);
            const before_deinit = try check(&parser, &meter);
            try std.testing.expect(before_deinit.retained_bytes > 0);
            parser.deinit();
            try std.testing.expectEqual(@as(usize, 0), meter.live);
            try std.testing.expect(meter.allocations > 0);
            try std.testing.expect(meter.frees > 0);
        }
    }
}

test "M14 reservations and replacement allocations do not bypass the backing budget" {
    var meter: Meter = .{};
    var budget = internal.memory.MemoryBudget.init(256);
    var wrapper: internal.memory.BudgetAllocator = .{ .parent = meter.allocator(), .budget = &budget };
    const a = wrapper.allocator();
    const held = try a.alloc(u8, 80);
    defer a.free(held);
    @memset(held, 0xA5);
    var reservation = try budget.reserve(160);
    try std.testing.expectEqual(@as(usize, 80), meter.live);
    try std.testing.expectEqual(@as(usize, 160), budget.snapshot().reserved_bytes);
    try std.testing.expectEqual(@as(usize, 240), budget.snapshot().peak_total_bytes);
    // Allocation may not steal reserved bytes even when the backing
    // allocator itself has ample free physical memory.
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 17));
    try std.testing.expectEqual(@as(u8, 0xA5), held[0]);
    try std.testing.expectEqual(@as(usize, 80), meter.live);
    try reservation.cancel();
    const replacement = try a.alloc(u8, 144);
    @memset(replacement, 0x3F);
    try std.testing.expectEqual(@as(usize, 224), meter.live);
    try std.testing.expectEqual(@as(usize, 224), budget.snapshot().live_bytes);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 33));
    try std.testing.expectEqual(@as(u8, 0x3F), replacement[143]);
    a.free(replacement);
    try std.testing.expectEqual(@as(usize, 80), budget.snapshot().live_bytes);
    try std.testing.expectEqual(@as(usize, 80), meter.live);
}


test "M14 consumer-held ASCII list lease reports recoverable pressure without losing the staged record" {
    const header = "ply\nformat ascii 1.0\nelement face 2\nproperty list ushort int ids\nend_header\n";
    var fixture: std.ArrayList(u8) = .empty;
    defer fixture.deinit(std.testing.allocator);
    try fixture.appendSlice(std.testing.allocator, header);
    for (0..2) |record| {
        try fixture.appendSlice(std.testing.allocator, "1000");
        for (0..1000) |_| {
            try fixture.appendSlice(std.testing.allocator, if (record == 0) " 9" else " 8");
        }
        try fixture.append(std.testing.allocator, '\n');
    }

    // Derive the pressure limit from observed allocations, not from guessed
    // platform-specific pool/allocator overhead.
    var probe_meter: Meter = .{};
    var probe_reader: std.Io.Reader = .fixed(fixture.items);
    var probe = try Parser.init(probe_meter.allocator(), std.testing.io, &probe_reader, .{
        .memory_budget = 1024 * 1024, .chunk_size = 1024,
    });
    var probe_first = (try probe.next()).?;
    const first_live = (try check(&probe, &probe_meter)).live_bytes;
    var probe_second = (try probe.next()).?;
    const second_live = (try check(&probe, &probe_meter)).live_bytes;
    try std.testing.expect(second_live > first_live + 2);
    probe_first.release();
    probe_second.release();
    probe.deinit();
    try std.testing.expectEqual(@as(usize, 0), probe_meter.live);
    const limit = first_live + (second_live - first_live) / 2;

    var meter: Meter = .{};
    var reader: std.Io.Reader = .fixed(fixture.items);
    var parser = try Parser.init(meter.allocator(), std.testing.io, &reader, .{
        .memory_budget = limit, .chunk_size = 1024,
    });
    defer {
        parser.deinit();
        std.debug.assert(meter.live == 0);
    }
    var first = (try parser.next()).?;
    defer if (first.isValid()) first.release();
    const list_a = try first.listColumn(0);
    try std.testing.expectEqual(@as(usize, 1000), list_a.row(0).?.i32.len);
    try std.testing.expectEqual(@as(i32, 9), list_a.row(0).?.i32[0]);
    try std.testing.expectError(error.MemoryPressure, parser.next());
    try std.testing.expectEqual(@as(i32, 9), (try first.listColumn(0)).row(0).?.i32[999]);
    _ = try check(&parser, &meter);

    first.release();
    var second = (try parser.next()).?;
    defer if (second.isValid()) second.release();
    try std.testing.expectEqual(@as(u64, 1), second.info().first_record);
    const list_b = try second.listColumn(0);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1000 }, list_b.offsets);
    try std.testing.expectEqual(@as(i32, 8), list_b.row(0).?.i32[999]);
    second.release();
    try std.testing.expect((try parser.next()) == null);
    const final_stats = try check(&parser, &meter);
    try std.testing.expectEqual(@as(usize, 0), final_stats.leased_bytes);
    try std.testing.expect(final_stats.peak_total_bytes <= limit);
}
