//! Phase 9: exact-once identity, list offsets, non-seekable-compatible
//! record alignment, and task errors through the native std.Io pipeline.
const std = @import("std");
const z = @import("zply");

const Kind = enum { scalar, lists, crlf };

fn source(a: std.mem.Allocator, kind: Kind, count: usize, bad_record: ?usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    const schema = switch (kind) {
        .scalar, .crlf => "property float x\nproperty int id\nproperty double y\n",
        .lists => "property uchar material\nproperty list uchar int indices\nproperty float weight\n",
    };
    const header = try std.fmt.allocPrint(a, "ply\nformat ascii 1.0\nelement vertex {d}\n{s}end_header\n", .{ count, schema });
    defer a.free(header);
    try bytes.appendSlice(a, header);
    var buf: [256]u8 = undefined;
    for (0..count) |i| {
        if (bad_record != null and i == bad_record.?) {
            try bytes.appendSlice(a, "3 invalid 4\n");
            continue;
        }
        const line = switch (kind) {
            .scalar, .crlf => try std.fmt.bufPrint(&buf, "{d} {d} {d}{s}", .{
                i % 1000,                                           i, (i * 2) % 10000,
                if (kind == .crlf and i % 2 == 0) "\r\n" else "\n",
            }),
            .lists => blk: {
                const n = i % 5;
                var cursor: usize = 0;
                const head = try std.fmt.bufPrint(buf[cursor..], "{d} {d}", .{ i % 251, n });
                cursor += head.len;
                for (0..n) |j| {
                    const item = try std.fmt.bufPrint(buf[cursor..], " {d}", .{i * 10 + j});
                    cursor += item.len;
                }
                const tail = try std.fmt.bufPrint(buf[cursor..], " {d}\n", .{i % 100});
                cursor += tail.len;
                break :blk buf[0..cursor];
            },
        };
        try bytes.appendSlice(a, line);
    }
    return try bytes.toOwnedSlice(a);
}

fn check(io: std.Io, kind: Kind, count: usize, ordered: bool) !void {
    const a = std.testing.allocator;
    const data = try source(a, kind, count, null);
    defer a.free(data);
    var reader: std.Io.Reader = .fixed(data);
    var parser = try z.Parser.init(a, io, &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = ordered,
    });
    defer parser.deinit();
    const seen = try a.alloc(bool, count);
    defer a.free(seen);
    @memset(seen, false);
    var delivered: usize = 0;
    var last_sequence: u64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        if (ordered) {
            try std.testing.expectEqual(last_sequence, info.sequence);
            try std.testing.expectEqual(@as(u64, @intCast(delivered)), info.first_record);
            last_sequence += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), info.element_index);
        const base: usize = @intCast(info.first_record);
        switch (kind) {
            .scalar, .crlf => {
                const xs = try batch.typedColumn(f32, 0);
                const ids = try batch.typedColumn(i32, 1);
                const ys = try batch.typedColumn(f64, 2);
                try std.testing.expectEqual(info.record_count, xs.len);
                for (xs, ids, ys, 0..) |x, id, y, row| {
                    const index = base + row;
                    try std.testing.expect(index < count and !seen[index]);
                    seen[index] = true;
                    try std.testing.expectEqual(@as(f32, @floatFromInt(index % 1000)), x);
                    try std.testing.expectEqual(@as(i32, @intCast(index)), id);
                    try std.testing.expectEqual(@as(f64, @floatFromInt((index * 2) % 10000)), y);
                }
            },
            .lists => {
                const materials = try batch.typedColumn(u8, 0);
                const indices = try batch.listColumn(1);
                const weights = try batch.typedColumn(f32, 2);
                try std.testing.expectEqual(info.record_count + 1, indices.offsets.len);
                for (0..info.record_count) |row| {
                    const index = base + row;
                    try std.testing.expect(index < count and !seen[index]);
                    seen[index] = true;
                    try std.testing.expectEqual(@as(u8, @intCast(index % 251)), materials[row]);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(index % 100)), weights[row]);
                    const v = indices.row(row).?.i32;
                    try std.testing.expectEqual(index % 5, v.len);
                    for (v, 0..) |item, j| try std.testing.expectEqual(@as(i32, @intCast(index * 10 + j)), item);
                }
            },
        }
        delivered += info.record_count;
        const memory = parser.memoryStats();
        try std.testing.expect(memory.peak_total_bytes <= memory.budget_bytes);
        try std.testing.expect(memory.live_bytes + memory.reserved_bytes <= memory.budget_bytes);
    }
    try std.testing.expectEqual(count, delivered);
    for (seen) |entry| try std.testing.expect(entry);
    try std.testing.expect((try parser.next()) == null);
    const stats = parser.executionStats();
    try std.testing.expect(stats.admitted_tasks > 1);
}

test "Phase 9 scalar chunks exactly match their source in ordered and unordered native Io" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try check(threaded.io(), .scalar, 30_000, true);
    try check(threaded.io(), .scalar, 30_000, false);
}

test "Phase 9 mixed list columns decode into independent multi-record offsets" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try check(threaded.io(), .lists, 20_000, true);
    try check(threaded.io(), .lists, 20_000, false);
}

test "Phase 9 CRLF chunks preserve byte-aligned record ranges" {
    try check(std.testing.io, .crlf, 12_000, true);
}

test "Phase 9 single-threaded Io falls back to inline decoding" {
    try check(std.testing.io, .scalar, 12_000, true);
    try check(std.testing.io, .lists, 12_000, true);
}

test "Phase 9 bad float reports an exact chunk-relative record and token" {
    const a = std.testing.allocator;
    const bad_at: usize = 9000;
    const data = try source(a, .scalar, 20_000, bad_at);
    defer a.free(data);
    var reader: std.Io.Reader = .fixed(data);
    var parser = try z.Parser.init(a, std.testing.io, &reader, .{ .chunk_size = 128 * 1024 });
    defer parser.deinit();
    var delivered: usize = 0;
    while (true) {
        const value = parser.next() catch |err| {
            try std.testing.expectEqual(error.InvalidNumber, err);
            break;
        } orelse return error.MissingExpectedFailure;
        var batch = value;
        delivered += batch.info().record_count;
        batch.release();
    }
    try std.testing.expect(delivered <= bad_at);
    const diagnostic = parser.asciiDiagnostic().?;
    try std.testing.expectEqual(@as(u64, bad_at), diagnostic.record_index.?);
    try std.testing.expectEqual(@as(u64, 1), diagnostic.property_index.?);
    try std.testing.expect(diagnostic.token_byte_offset.? > diagnostic.byte_offset.?);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

test "Phase 9 multiple element transitions and zero-property records leave trailing data unread" {
    const a = std.testing.allocator;
    const scalar_count = 500;
    const empty_count = 600;
    const header = "ply\nformat ascii 1.0\n" ++
        "element vertex 500\nproperty int id\n" ++
        "element empty 600\n" ++
        "element face 500\nproperty list uchar int indices\n" ++
        "end_header\n";
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, header);
    var line: [40]u8 = undefined;
    for (0..scalar_count) |i| try bytes.appendSlice(a, try std.fmt.bufPrint(&line, "{d}\n", .{i}));
    for (0..empty_count) |_| try bytes.append(a, '\n');
    for (0..scalar_count) |i| try bytes.appendSlice(a, try std.fmt.bufPrint(&line, "2 {d} {d}\n", .{ i, i + 1 }));
    try bytes.appendSlice(a, "TRAILING");
    var reader: std.Io.Reader = .fixed(bytes.items);
    var parser = try z.Parser.init(a, std.testing.io, &reader, .{ .chunk_size = 128 * 1024, .memory_budget = 8 * 1024 * 1024 });
    defer parser.deinit();
    var counts: [3]usize = @splat(0);
    var seq: u64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(seq, info.sequence);
        try std.testing.expectEqual(@as(u64, @intCast(counts[info.element_index])), info.first_record);
        const first: usize = @intCast(info.first_record);
        switch (info.element_index) {
            0 => {
                const ids = try batch.typedColumn(i32, 0);
                for (ids, 0..) |id, row| try std.testing.expectEqual(@as(i32, @intCast(first + row)), id);
            },
            1 => try std.testing.expectEqual(@as(usize, 0), batch.columnCount()),
            2 => {
                const indices = try batch.listColumn(0);
                for (0..info.record_count) |row| {
                    const v = indices.row(row).?.i32;
                    try std.testing.expectEqualSlices(i32, &.{ @as(i32, @intCast(first + row)), @as(i32, @intCast(first + row + 1)) }, v);
                }
            },
            else => return error.InvalidElement,
        }
        counts[info.element_index] += info.record_count;
        seq += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ scalar_count, empty_count, scalar_count }, &counts);
    try std.testing.expectEqual(@as(u8, 'T'), try reader.takeByte());
}

// A malformed list count in the middle of a staged chunk must not discard
// valid preceding records. Preflight splits at the bad record boundary.
test "Phase 9 list preflight preserves the valid prefix before a negative count" {
    const a = std.testing.allocator;
    const count: usize = 260;
    const header = try std.fmt.allocPrint(
        a,
        "ply\nformat ascii 1.0\nelement face {d}\n" ++
            "property list short int indices\nend_header\n",
        .{count},
    );
    defer a.free(header);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, header);
    for (0..count - 1) |_| try bytes.appendSlice(a, "0\n");
    const bad_offset: u64 = @intCast(bytes.items.len);
    try bytes.appendSlice(a, "-1\n");
    var reader: std.Io.Reader = .fixed(bytes.items);
    var parser = try z.Parser.init(a, std.testing.io, &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 8 * 1024 * 1024,
    });
    defer parser.deinit();
    var batch = (try parser.next()).?;
    try std.testing.expectEqual(@as(usize, count - 1), batch.info().record_count);
    try std.testing.expectEqual(@as(u64, 0), batch.info().first_record);
    const indices = try batch.listColumn(0);
    try std.testing.expectEqual(@as(usize, count), indices.offsets.len);
    for (indices.offsets) |off| try std.testing.expectEqual(@as(usize, 0), off);
    batch.release();
    try std.testing.expectError(error.NegativeListCount, parser.next());
    const diagnostic = parser.asciiDiagnostic().?;
    try std.testing.expectEqual(@as(u64, count - 1), diagnostic.record_index.?);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.property_index.?);
    try std.testing.expectEqual(bad_offset, diagnostic.byte_offset.?);
    try std.testing.expectEqual(bad_offset, diagnostic.token_byte_offset.?);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

// Keep completed batches leased until the decoder runs out of budget, then
// release them without rewinding the reader. Every declared record must
// still be emitted exactly once and the peak accounting must stay bounded.
test "Phase 9 ASCII retained batches recover from budget pressure without duplicates" {
    const a = std.testing.allocator;
    const record_count: usize = 30_000;
    const data = try source(a, .scalar, record_count, null);
    defer a.free(data);
    var reader: std.Io.Reader = .fixed(data);
    const budget: usize = 256 * 1024;
    var parser = try z.Parser.init(a, std.testing.io, &reader, .{
        .chunk_size = 64 * 1024,
        .memory_budget = budget,
        .preserve_order = true,
    });
    defer parser.deinit();

    // The parser may shrink batches to only a few records under pressure;
    // no fixed number of leases is guaranteed to exhaust the byte budget.
    // Test bookkeeping is allocated outside the parser-managed budget.
    var held: std.ArrayList(z.Batch) = .empty;
    defer {
        for (held.items) |*batch| batch.release();
        held.deinit(a);
    }
    var delivered: usize = 0;
    var pressure_events: usize = 0;
    while (true) {
        const maybe_batch = parser.next() catch |err| {
            if (err != error.MemoryPressure) return err;
            try std.testing.expect(held.items.len > 0);
            pressure_events += 1;
            for (held.items) |*batch| batch.release();
            held.clearRetainingCapacity();
            continue;
        };
        var batch = maybe_batch orelse break;
        // `next` transfers one live lease. Any failed assertion or append
        // must release this lease before `parser.deinit` can run.
        var transferred = false;
        defer if (!transferred) batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(u64, @intCast(delivered)), info.first_record);
        const ids = try batch.typedColumn(i32, 1);
        try std.testing.expectEqual(info.record_count, ids.len);
        for (ids, 0..) |id, row| {
            try std.testing.expectEqual(@as(i32, @intCast(delivered + row)), id);
        }
        delivered += info.record_count;
        try held.append(a, batch);
        transferred = true;
        const memory = parser.memoryStats();
        try std.testing.expect(memory.live_bytes + memory.reserved_bytes <= budget);
    }
    try std.testing.expectEqual(record_count, delivered);
    try std.testing.expect(pressure_events > 0);
    const stats = parser.memoryStats();
    try std.testing.expect(stats.peak_total_bytes <= budget);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
}

// A list's decoded f64 payload is much larger than its short ASCII tokens.
// With a small parser budget, a staged group may be too expensive to admit
// as one batch even though every individual record fits. The parser must
// reduce the group at record boundaries and deliver every list exactly once.
test "Phase 9 list-heavy ASCII admission splits on decoded memory pressure" {
    const a = std.testing.allocator;
    const record_count: usize = 500;
    const values_per_record: usize = 512;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    try data.appendSlice(a, "ply\nformat ascii 1.0\nelement face 500\n" ++
        "property uint id\nproperty list ushort double weights\nend_header\n");
    var line: [64]u8 = undefined;
    for (0..record_count) |i| {
        try data.appendSlice(a, try std.fmt.bufPrint(&line, "{d} {d}", .{ i, values_per_record }));
        for (0..values_per_record) |_| try data.appendSlice(a, " 0");
        try data.append(a, '\n');
    }

    const budget: usize = 192 * 1024;
    var reader: std.Io.Reader = .fixed(data.items);
    var parser = try z.Parser.init(a, std.testing.io, &reader, .{
        .chunk_size = 64 * 1024,
        .memory_budget = budget,
        .preserve_order = true,
    });
    defer parser.deinit();

    var delivered: usize = 0;
    var batches: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(u64, @intCast(delivered)), info.first_record);
        const ids = try batch.typedColumn(u32, 0);
        const weights = try batch.listColumn(1);
        try std.testing.expectEqual(info.record_count, ids.len);
        try std.testing.expectEqual(info.record_count + 1, weights.offsets.len);
        for (0..info.record_count) |row| {
            try std.testing.expectEqual(@as(u32, @intCast(delivered + row)), ids[row]);
            const values = weights.row(row).?.f64;
            try std.testing.expectEqual(values_per_record, values.len);
            try std.testing.expectEqual(@as(f64, 0), values[0]);
            try std.testing.expectEqual(@as(f64, 0), values[values.len - 1]);
        }
        delivered += info.record_count;
        batches += 1;
        const stats = parser.memoryStats();
        try std.testing.expect(stats.live_bytes + stats.reserved_bytes <= budget);
    }
    try std.testing.expectEqual(record_count, delivered);
    try std.testing.expect(batches > 1);
    const memory = parser.memoryStats();
    try std.testing.expect(memory.peak_total_bytes <= budget);
    try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
    try std.testing.expect(memory.batch_reductions > 0);
}

// Sweep allocator failures through initialization, record staging, boundary
// indexing, preflight, output allocation, and task registration. The backing
// testing allocator detects leaks; no consumer may see a partially decoded
// batch when any of these allocations fails.
test "Phase 9 concurrent ASCII admission is safe across allocator failures" {
    const a = std.testing.allocator;
    const record_count: usize = 300;
    const data = try source(a, .lists, record_count, null);
    defer a.free(data);

    var failures: usize = 0;
    var successes: usize = 0;
    for (0..160) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var reader: std.Io.Reader = .fixed(data);
        if (z.Parser.init(failing.allocator(), std.testing.io, &reader, .{
            .chunk_size = 64 * 1024,
            .memory_budget = 2 * 1024 * 1024,
        })) |value| {
            var parser = value;
            defer parser.deinit();
            var delivered: usize = 0;
            var failed = false;
            while (true) {
                const next = parser.next() catch |err| {
                    try std.testing.expect(err == error.OutOfMemory or
                        err == error.ResourceLimitExceeded or
                        err == error.BatchCapacityUnavailable);
                    failures += 1;
                    failed = true;
                    break;
                } orelse break;
                var batch = next;
                defer batch.release();
                const info = batch.info();
                try std.testing.expectEqual(@as(u64, @intCast(delivered)), info.first_record);
                delivered += info.record_count;
            }
            if (!failed) {
                try std.testing.expectEqual(record_count, delivered);
                successes += 1;
            }
            const memory = parser.memoryStats();
            try std.testing.expect(memory.peak_total_bytes <= memory.budget_bytes);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
    }
    try std.testing.expect(failures > 0);
    try std.testing.expect(successes > 0);
}
