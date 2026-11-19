//! Phase 11 M15: replay fixed, self-authored PLY regression fixtures.
//! Tests only the zply_internals module universe (Zig 0.17.1).
const std = @import("std");
const internals = @import("zply_internals");
const Parser = internals.parser.Parser;
const Batch = internals.parser.Batch;
const Diagnostic = internals.errors.Diagnostic;
const FaultReader = @import("fault_reader.zig").FaultReader;

const Kind = enum { xyz_rgb, face_camera };
const ValidCase = struct {
    name: []const u8,
    bytes: []const u8,
    kind: Kind,
};
const valid_cases = [_]ValidCase{
    .{ .name = "valid_ascii_xyz_rgb.ply", .bytes = @embedFile("fixtures/regressions/valid_ascii_xyz_rgb.ply"), .kind = .xyz_rgb },
    .{ .name = "valid_little_xyz_rgb.ply", .bytes = @embedFile("fixtures/regressions/valid_little_xyz_rgb.ply"), .kind = .xyz_rgb },
    .{ .name = "valid_big_xyz_rgb.ply", .bytes = @embedFile("fixtures/regressions/valid_big_xyz_rgb.ply"), .kind = .xyz_rgb },
    .{ .name = "valid_ascii_mixed.ply", .bytes = @embedFile("fixtures/regressions/valid_ascii_mixed.ply"), .kind = .face_camera },
    .{ .name = "valid_little_mixed.ply", .bytes = @embedFile("fixtures/regressions/valid_little_mixed.ply"), .kind = .face_camera },
    .{ .name = "valid_big_mixed.ply", .bytes = @embedFile("fixtures/regressions/valid_big_mixed.ply"), .kind = .face_camera },
};

const InvalidCase = struct {
    name: []const u8,
    bytes: []const u8,
    expected: anyerror,
    during_init: bool = false,
};
const invalid_cases = [_]InvalidCase{
    .{ .name = "invalid_magic.ply", .bytes = @embedFile("fixtures/regressions/invalid_magic.ply"), .expected = error.InvalidMagic, .during_init = true },
    .{ .name = "invalid_version.ply", .bytes = @embedFile("fixtures/regressions/invalid_version.ply"), .expected = error.UnsupportedVersion, .during_init = true },
    .{ .name = "invalid_duplicate_format.ply", .bytes = @embedFile("fixtures/regressions/invalid_duplicate_format.ply"), .expected = error.DuplicateFormat, .during_init = true },
    .{ .name = "invalid_list_count_type.ply", .bytes = @embedFile("fixtures/regressions/invalid_list_count_type.ply"), .expected = error.InvalidListCountType, .during_init = true },
    .{ .name = "invalid_ascii_number.ply", .bytes = @embedFile("fixtures/regressions/invalid_ascii_number.ply"), .expected = error.InvalidNumber },
    .{ .name = "invalid_ascii_u8_overflow.ply", .bytes = @embedFile("fixtures/regressions/invalid_ascii_u8_overflow.ply"), .expected = error.IntegerOverflow },
    .{ .name = "invalid_little_truncated_u32.ply", .bytes = @embedFile("fixtures/regressions/invalid_little_truncated_u32.ply"), .expected = error.TruncatedBody },
    .{ .name = "invalid_big_truncated_u32.ply", .bytes = @embedFile("fixtures/regressions/invalid_big_truncated_u32.ply"), .expected = error.TruncatedBody },
    .{ .name = "invalid_little_list_payload.ply", .bytes = @embedFile("fixtures/regressions/invalid_little_list_payload.ply"), .expected = error.TruncatedListPayload },
    .{ .name = "invalid_big_list_payload.ply", .bytes = @embedFile("fixtures/regressions/invalid_big_list_payload.ply"), .expected = error.TruncatedListPayload },
    .{ .name = "invalid_little_list_count.ply", .bytes = @embedFile("fixtures/regressions/invalid_little_list_count.ply"), .expected = error.TruncatedListCount },
    .{ .name = "invalid_big_list_count.ply", .bytes = @embedFile("fixtures/regressions/invalid_big_list_count.ply"), .expected = error.TruncatedListCount },
    .{ .name = "invalid_negative_list_count.ply", .bytes = @embedFile("fixtures/regressions/invalid_negative_list_count.ply"), .expected = error.NegativeListCount },
};

const xyz = [_][3]f32{
    .{ 1, 2, 3 },
    .{ -0.0, -1.5, 0.5 },
    .{ 0.25, 4, 8 },
};
const rgb = [_][3]u8{
    .{ 255, 0, 17 },
    .{ 1, 2, 3 },
    .{ 7, 11, 13 },
};

fn verifyBatch(batch: *Batch, kind: Kind, seen: *[2]usize) !void {
    const info = batch.info();
    try std.testing.expect(info.record_count > 0);
    try std.testing.expect(info.element_index < (if (kind == .xyz_rgb) @as(usize, 1) else 2));
    const e = info.element_index;
    try std.testing.expectEqual(@as(u64, @intCast(seen[e])), info.first_record);
    if (kind == .face_camera and e == 1) {
        try std.testing.expectEqual(@as(usize, 2), seen[0]);
    }
    if (kind == .xyz_rgb) {
        try std.testing.expect(seen[0] + info.record_count <= 3);
        const x = try batch.typedColumn(f32, 0);
        const y = try batch.typedColumn(f32, 1);
        const z = try batch.typedColumn(f32, 2);
        const r = try batch.typedColumn(u8, 3);
        const g = try batch.typedColumn(u8, 4);
        const b = try batch.typedColumn(u8, 5);
        for (0..info.record_count) |j| {
            const idx = seen[0] + j;
            try std.testing.expectEqual(@as(u32, @bitCast(xyz[idx][0])), @as(u32, @bitCast(x[j])));
            try std.testing.expectEqual(@as(u32, @bitCast(xyz[idx][1])), @as(u32, @bitCast(y[j])));
            try std.testing.expectEqual(@as(u32, @bitCast(xyz[idx][2])), @as(u32, @bitCast(z[j])));
            try std.testing.expectEqual(rgb[idx][0], r[j]);
            try std.testing.expectEqual(rgb[idx][1], g[j]);
            try std.testing.expectEqual(rgb[idx][2], b[j]);
        }
    } else if (e == 0) {
        try std.testing.expect(seen[0] + info.record_count <= 2);
        const indices = try batch.listColumn(0);
        const confidence = try batch.typedColumn(f32, 1);
        try std.testing.expectEqual(info.record_count + 1, indices.offsets.len);
        try std.testing.expectEqual(@as(usize, 0), indices.offsets[0]);
        for (0..info.record_count) |j| {
            const idx = seen[0] + j;
            const values = indices.row(j).?.i32;
            if (idx == 0) {
                try std.testing.expectEqualSlices(i32, &.{ 0, 2, 4 }, values);
                try std.testing.expectEqual(@as(f32, 0.5), confidence[j]);
            } else {
                try std.testing.expectEqual(@as(usize, 0), values.len);
                try std.testing.expectEqual(@as(f32, 1.0), confidence[j]);
            }
        }
        try std.testing.expectEqual(indices.values.len(), indices.offsets[info.record_count]);
    } else {
        try std.testing.expect(seen[1] + info.record_count <= 1);
        const exposure = try batch.typedColumn(f64, 0);
        for (exposure) |value| try std.testing.expectEqual(@as(f64, 2), value);
    }
    seen[e] += info.record_count;
}

fn checkMemory(parser: *const Parser) !void {
    const memory = parser.memoryStats();
    try std.testing.expect(memory.live_bytes <= memory.budget_bytes);
    try std.testing.expect(memory.reserved_bytes <= memory.budget_bytes - memory.live_bytes);
    try std.testing.expect(memory.peak_total_bytes <= memory.budget_bytes);
}

test "M15 fixed valid PLY corpus survives fragmentation and chunk boundaries" {
    for (valid_cases) |case| {
        const fixture = try std.testing.allocator.alloc(u8, case.bytes.len + 4);
        defer std.testing.allocator.free(fixture);
        @memcpy(fixture[0..case.bytes.len], case.bytes);
        @memcpy(fixture[case.bytes.len..], "TAIL");
        for ([_][]const usize{ &.{1}, &.{ 2, 3, 5, 7 }, &.{ 64, 1, 128, 3 } }) |fragments| {
            for ([_]usize{ 24, 64 }) |chunk_size| {
                var source = FaultReader.init(fixture, .{ .fragments = fragments });
                const reader = source.reader();
                var parser = try Parser.init(std.testing.allocator, std.testing.io, reader, .{
                    .chunk_size = chunk_size,
                    .memory_budget = 2 * 1024 * 1024,
                });
                defer parser.deinit();
                var seen: [2]usize = .{ 0, 0 };
                while (try parser.next()) |value| {
                    var batch = value;
                    defer batch.release();
                    try verifyBatch(&batch, case.kind, &seen);
                    try checkMemory(&parser);
                }
                try std.testing.expectEqual(Parser.State.completed, parser.state);
                try std.testing.expectEqual(if (case.kind == .xyz_rgb) @as(usize, 3) else 2, seen[0]);
                try std.testing.expectEqual(if (case.kind == .xyz_rgb) @as(usize, 0) else 1, seen[1]);
                inline for ("TAIL") |byte| try std.testing.expectEqual(byte, try reader.takeByte());
            }
        }
    }
}

test "M15 permanent malformed corpus preserves public errors and diagnostic categories" {
    for (invalid_cases) |case| {
        for ([_][]const usize{ &.{1}, &.{ 2, 3, 5, 7 } }) |fragments| {
            var source = FaultReader.init(case.bytes, .{ .fragments = fragments });
            var diag: Diagnostic = .{ .category = .header };
            const result = Parser.initDetailed(std.testing.allocator, std.testing.io, source.reader(), .{
                .chunk_size = 64,
                .memory_budget = 2 * 1024 * 1024,
            }, &diag);
            if (result) |value| {
                var parser = value;
                defer parser.deinit();
                try std.testing.expect(!case.during_init);
                try std.testing.expectError(case.expected, parser.next());
                const failure = parser.lastDiagnostic() orelse return error.MissingRegressionDiagnostic;
                try std.testing.expectEqual(case.expected, failure.code.?);
                try std.testing.expectEqual(Diagnostic.categoryFor(case.expected), failure.category);
                try std.testing.expectEqual(Parser.State.failed, parser.state);
                try std.testing.expectError(error.InvalidProducerState, parser.next());
                try checkMemory(&parser);
            } else |err| {
                try std.testing.expect(case.during_init);
                try std.testing.expectEqual(case.expected, @as(anyerror, err));
                try std.testing.expectEqual(case.expected, diag.code.?);
                try std.testing.expectEqual(Diagnostic.categoryFor(case.expected), diag.category);
            }
        }
    }
}

test "M15 every replayed fixture has documented expectations" {
    const index = @embedFile("fixtures/regressions/README.md");
    for (valid_cases) |case| try std.testing.expect(std.mem.indexOf(u8, index, case.name) != null);
    for (invalid_cases) |case| try std.testing.expect(std.mem.indexOf(u8, index, case.name) != null);
}
