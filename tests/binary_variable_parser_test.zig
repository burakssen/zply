//! Phase 10: public Parser.next() routes variable-width binary elements
//! through the existing task registry, completion queue and batch pool.
const std = @import("std");
const z = @import("zply");

const little = [_]u8{
    2, 10, 0, 0, 0,  11, 0, 0, 0, 0,  0, 128, 63, 3, 0, 7,  8,  9,
    0, 0,  0, 0, 64, 1,  0, 5, 1, 12, 0, 0,   0,  0, 0, 64, 64, 0,
    0,
};
const big = [_]u8{
    2, 0,  0, 0, 10, 0, 0, 0, 11, 63, 128, 0, 0,  0,  3,  7, 8, 9,
    0, 64, 0, 0, 0,  0, 1, 5, 1,  0,  0,   0, 12, 64, 64, 0, 0, 0,
    0,
};

fn input(allocator: std.mem.Allocator, endian: std.builtin.Endian) ![]u8 {
    const header = if (endian == .little)
        "ply\nformat binary_little_endian 1.0\nelement face 3\nproperty list uchar int neighbors\nproperty float confidence\nproperty list ushort uchar weights\nend_header\n"
    else
        "ply\nformat binary_big_endian 1.0\nelement face 3\nproperty list uchar int neighbors\nproperty float confidence\nproperty list ushort uchar weights\nend_header\n";
    const body: []const u8 = if (endian == .little) &little else &big;
    const result = try allocator.alloc(u8, header.len + body.len + 3);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len .. header.len + body.len], body);
    @memcpy(result[header.len + body.len ..], "END");
    return result;
}

test "Phase 10 public Parser.next handles both endian binary lists, splitting and trailing data" {
    inline for (.{ .little, .big }) |endian| {
        inline for (.{ true, false }) |ordered| {
            const data = try input(std.testing.allocator, endian);
            defer std.testing.allocator.free(data);
            var reader: std.Io.Reader = .fixed(data);
            var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
                .chunk_size = 24,
                .memory_budget = 2 * 1024 * 1024,
                .preserve_order = ordered,
            });
            defer parser.deinit();
            var seen = [_]bool{ false, false, false };
            var batches: usize = 0;
            while (try parser.next()) |batch_value| {
                var batch = batch_value;
                defer batch.release();
                batches += 1;
                const info = batch.info();
                try std.testing.expectEqual(@as(usize, 0), info.element_index);
                const neighbors = try batch.listColumn(0);
                const confidences = try batch.typedColumn(f32, 1);
                const weights = try batch.listColumn(2);
                for (0..info.record_count) |row| {
                    const index = @as(usize, @intCast(info.first_record)) + row;
                    try std.testing.expect(index < seen.len);
                    try std.testing.expect(!seen[index]);
                    seen[index] = true;
                    const expected_neighbors: []const i32 = switch (index) {
                        0 => &.{ 10, 11 },
                        1 => &.{},
                        else => &.{12},
                    };
                    const expected_weights: []const u8 = switch (index) {
                        0 => &.{ 7, 8, 9 },
                        1 => &.{5},
                        else => &.{},
                    };
                    try std.testing.expectEqualSlices(i32, expected_neighbors, neighbors.row(row).?.i32);
                    try std.testing.expectEqualSlices(u8, expected_weights, weights.row(row).?.u8);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(index + 1)), confidences[row]);
                }
                const memory = parser.memoryStats();
                try std.testing.expect(memory.peak_total_bytes <= memory.budget_bytes);
            }
            try std.testing.expect(batches > 1);
            for (seen) |was_seen| try std.testing.expect(was_seen);
            try std.testing.expectEqual(@as(u8, 'E'), try reader.takeByte());
            try std.testing.expectEqual(@as(u8, 'N'), try reader.takeByte());
            try std.testing.expectEqual(@as(u8, 'D'), try reader.takeByte());
            try std.testing.expectEqual(@as(usize, 0), parser.executionStats().active_decodes);
        }
    }
}

test "Phase 10 fixed-variable-fixed binary element transitions preserve record identities" {
    const header = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nelement face 3\nproperty list uchar int neighbors\nproperty float confidence\nproperty list ushort uchar weights\nelement camera 1\nproperty int id\nend_header\n";
    const before = [_]u8{ 0, 0, 128, 63 }; // one vertex, x = 1.0
    const after = [_]u8{ 99, 0, 0, 0 }; // one camera, id = 99
    const bytes = try std.testing.allocator.alloc(u8, header.len + before.len + little.len + after.len);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);
    @memcpy(bytes[header.len .. header.len + before.len], &before);
    @memcpy(bytes[header.len + before.len .. header.len + before.len + little.len], &little);
    @memcpy(bytes[header.len + before.len + little.len ..], &after);
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 24,
        .memory_budget = 2 * 1024 * 1024,
    });
    defer parser.deinit();
    var seen_vertex = false;
    var seen_face = [_]bool{ false, false, false };
    var seen_camera = false;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        switch (info.element_index) {
            0 => {
                try std.testing.expect(!seen_vertex);
                seen_vertex = true;
                try std.testing.expectEqual(@as(f32, 1.0), (try batch.typedColumn(f32, 0))[0]);
            },
            1 => {
                for (0..info.record_count) |r| {
                    const i = @as(usize, @intCast(info.first_record)) + r;
                    try std.testing.expect(!seen_face[i]);
                    seen_face[i] = true;
                }
            },
            2 => {
                try std.testing.expect(!seen_camera);
                seen_camera = true;
                try std.testing.expectEqual(@as(i32, 99), (try batch.typedColumn(i32, 0))[0]);
            },
            else => return error.UnexpectedElement,
        }
    }
    try std.testing.expect(seen_vertex and seen_camera);
    for (seen_face) |v| try std.testing.expect(v);
}

test "Phase 10 public Parser reports terminal truncated binary list without publishing partial record" {
    const full = try input(std.testing.allocator, .little);
    defer std.testing.allocator.free(full);
    // Truncate inside the final record, excluding the trailing marker.
    const chopped = full[0 .. full.len - 7];
    var reader: std.Io.Reader = .fixed(chopped);
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 24,
        .memory_budget = 2 * 1024 * 1024,
    });
    defer parser.deinit();
    var consumed: usize = 0;
    var got_truncation = false;
    while (true) {
        const next_value = parser.next() catch |err| {
            try std.testing.expect(err == error.TruncatedRecord or err == error.TruncatedListCount or err == error.TruncatedListPayload);
            got_truncation = true;
            break;
        };
        const value = next_value orelse break;
        var batch = value;
        defer batch.release();
        consumed += batch.info().record_count;
    }
    try std.testing.expect(got_truncation);
    try std.testing.expectEqual(@as(usize, 2), consumed);
    try std.testing.expect(parser.binaryDiagnostic() != null);
}

test "Phase 10 binary-variable tasks use caller's native threaded executor" {
    const count: usize = 10_000;
    const header = "ply\nformat binary_little_endian 1.0\nelement face 10000\nproperty list uchar uint indices\nend_header\n";
    // A 17-byte face (count=4, four u32 indices).
    const bytes = try std.testing.allocator.alloc(u8, header.len + count * 17);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);
    for (0..count) |i| {
        const start = header.len + i * 17;
        bytes[start] = 4;
        for (0..4) |j| {
            std.mem.writeInt(u32, bytes[start + 1 + j * 4 ..][0..4], @intCast(i + j), .little);
        }
    }
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try z.Parser.init(std.testing.allocator, threaded.io(), &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 8 * 1024 * 1024,
        .preserve_order = false,
    });
    defer parser.deinit();
    const seen = try std.testing.allocator.alloc(bool, count);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var batches: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        batches += 1;
        const faces = try batch.listColumn(0);
        for (0..info.record_count) |row| {
            const i = @as(usize, @intCast(info.first_record)) + row;
            try std.testing.expect(i < count and !seen[i]);
            seen[i] = true;
            try std.testing.expectEqualSlices(u32, &.{
                @as(u32, @intCast(i)),     @as(u32, @intCast(i + 1)),
                @as(u32, @intCast(i + 2)), @as(u32, @intCast(i + 3)),
            }, faces.row(row).?.u32);
        }
        const mem = parser.memoryStats();
        try std.testing.expect(mem.live_bytes + mem.reserved_bytes <= mem.budget_bytes);
    }
    for (seen) |ok| try std.testing.expect(ok);
    try std.testing.expect(batches > 1);
    const stats = parser.executionStats();
    try std.testing.expect(stats.native_submissions > 0);
    try std.testing.expectEqual(@as(usize, 0), stats.active_decodes);
}
