//! Phase 11 M12: reader faults and backing-allocator failures through the
//! end-to-end parser. Use only the internal module universe (Zig 0.17.1).
const std = @import("std");
const internal = @import("zply_internals");
const Parser = internal.parser.Parser;
const Batch = internal.parser.Batch;
const Diagnostic = internal.errors.Diagnostic;
const FaultReader = @import("fault_reader.zig").FaultReader;
const Fault = @import("fault_reader.zig").Fault;

const ascii_header = "ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\n" ++
    "property list ushort short ids\nproperty uchar flag\nend_header\n";
const ascii_body = "1.5 2 4 -2 17\n-0 0 18\n";

const le_header = "ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\n" ++
    "property list ushort short ids\nproperty uchar flag\nend_header\n";
const le_body = "\x00\x00\xc0\x3f\x02\x00\x04\x00\xfe\xff\x11" ++
    "\x00\x00\x00\x80\x00\x00\x12";

const be_header = "ply\nformat binary_big_endian 1.0\nelement vertex 2\nproperty float x\n" ++
    "property list ushort short ids\nproperty uchar flag\nend_header\n";
const be_body = "\x3f\xc0\x00\x00\x00\x02\x00\x04\xff\xfe\x11" ++
    "\x80\x00\x00\x00\x00\x00\x12";

const Fixture = struct {
    header: []const u8,
    body: []const u8,
    cuts: []const usize,
};

const fixtures = [_]Fixture{
    .{ .header = ascii_header, .body = ascii_body, .cuts = &.{ 0, 2, 8, 14, ascii_body.len - 1 } },
    .{ .header = le_header, .body = le_body, .cuts = &.{ 0, 1, 5, 6, 8, 10, le_body.len - 1 } },
    .{ .header = be_header, .body = be_body, .cuts = &.{ 0, 1, 5, 6, 8, 10, be_body.len - 1 } },
};

fn sourceFor(fixture: Fixture, tail: []const u8) ![]u8 {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, fixture.header.len + fixture.body.len + tail.len);
    @memcpy(bytes[0..fixture.header.len], fixture.header);
    @memcpy(bytes[fixture.header.len..][0..fixture.body.len], fixture.body);
    @memcpy(bytes[fixture.header.len + fixture.body.len ..], tail);
    return bytes;
}

fn checkBatch(batch: *Batch, next: *usize) !void {
    const info = batch.info();
    try std.testing.expectEqual(@as(usize, 0), info.element_index);
    try std.testing.expectEqual(@as(u64, @intCast(next.*)), info.first_record);
    try std.testing.expect(info.record_count > 0);
    try std.testing.expect(next.* + info.record_count <= 2);
    const x = try batch.typedColumn(f32, 0);
    const ids = try batch.listColumn(1);
    const flags = try batch.typedColumn(u8, 2);
    for (0..info.record_count) |j| {
        const i = next.* + j;
        const expected_x: f32 = if (i == 0) 1.5 else -0.0;
        try std.testing.expectEqual(@as(u32, @bitCast(expected_x)), @as(u32, @bitCast(x[j])));
        try std.testing.expectEqual(@as(u8, @intCast(17 + i)), flags[j]);
        const list = ids.row(j).?.i16;
        if (i == 0) {
            try std.testing.expectEqualSlices(i16, &.{ 4, -2 }, list);
        } else {
            try std.testing.expectEqual(@as(usize, 0), list.len);
        }
    }
    next.* += info.record_count;
}

fn assertAccounting(parser: *const Parser) !void {
    const mem = parser.memoryStats();
    try std.testing.expect(mem.live_bytes <= mem.budget_bytes);
    try std.testing.expect(mem.reserved_bytes <= mem.budget_bytes - mem.live_bytes);
    try std.testing.expect(mem.peak_total_bytes <= mem.budget_bytes);
}

test "M12 valid stream survives one-byte and irregular non-seekable reads" {
    for (fixtures) |fixture| {
        const bytes = try sourceFor(fixture, "TAIL");
        defer std.testing.allocator.free(bytes);
        for ([_][]const usize{ &.{1}, &.{ 2, 3, 5, 7 }, &.{ 64, 1, 128, 3 }, &.{4096} }) |pattern| {
            var source = FaultReader.init(bytes, .{ .fragments = pattern });
            const reader = source.reader();
            var parser = try Parser.init(std.testing.allocator, std.testing.io, reader, .{
                .chunk_size = 16, .memory_budget = 2 * 1024 * 1024,
            });
            defer parser.deinit();
            var seen: usize = 0;
            while (try parser.next()) |value| {
                var batch = value;
                defer batch.release();
                try checkBatch(&batch, &seen);
                try assertAccounting(&parser);
            }
            try std.testing.expectEqual(@as(usize, 2), seen);
            try std.testing.expectEqual(Parser.State.completed, parser.state);
            inline for ("TAIL") |byte| try std.testing.expectEqual(byte, try reader.takeByte());
        }
    }
}

test "M12 header reader failures report stable initialization diagnostics" {
    for (fixtures) |fixture| {
        const bytes = try sourceFor(fixture, "");
        defer std.testing.allocator.free(bytes);
        for ([_]usize{ 0, 2, fixture.header.len - 2 }) |cut| {
            var source = FaultReader.init(bytes, .{ .fragments = &.{ 1, 2, 3 }, .cutoff = cut, .fault = .read_failed });
            var diag: Diagnostic = .{ .category = .header };
            const result = Parser.initDetailed(std.testing.allocator, std.testing.io, source.reader(), .{}, &diag);
            if (result) |value| {
                var parser = value;
                parser.deinit();
                return error.ExpectedHeaderReadFailure;
            } else |err| try std.testing.expectEqual(error.ReadFailed, err);
            try std.testing.expectEqual(error.ReadFailed, diag.code.?);
            try std.testing.expectEqual(Diagnostic.Category.reader, diag.category);
            try std.testing.expect(source.position <= cut);
        }
    }
}

test "M12 injected body ReadFailed and EOF remain distinct at structural boundaries" {
    for (fixtures) |fixture| {
        const bytes = try sourceFor(fixture, "");
        defer std.testing.allocator.free(bytes);
        for (fixture.cuts) |relative_cut| {
            inline for (.{ Fault.read_failed, Fault.eof }) |fault| {
                const cut = fixture.header.len + relative_cut;
                var source = FaultReader.init(bytes, .{ .fragments = &.{ 1, 3, 2, 7 }, .cutoff = cut, .fault = fault });
                var parser = try Parser.init(std.testing.allocator, std.testing.io, source.reader(), .{
                    .chunk_size = 64, .memory_budget = 2 * 1024 * 1024,
                });
                defer parser.deinit();
                var seen: usize = 0;
                var got_error = false;
                for (0..6) |_| {
                    const result = parser.next() catch |err| {
                        const diag = parser.lastDiagnostic() orelse return error.MissingDiagnostic;
                        try std.testing.expectEqual(err, diag.code.?);
                        try std.testing.expectEqual(
                            if (fault == .read_failed) Diagnostic.Category.reader else Diagnostic.Category.truncation,
                            diag.category,
                        );
                        try std.testing.expectEqual(Parser.State.failed, parser.state);
                        got_error = true;
                        break;
                    };
                    if (result) |value| {
                        var batch = value;
                        defer batch.release();
                        try checkBatch(&batch, &seen);
                    } else return error.UnexpectedSuccessfulCompletion;
                }
                try std.testing.expect(got_error);
                try std.testing.expect(seen < 2);
                try std.testing.expect(source.position <= cut);
                try assertAccounting(&parser);
                try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
            }
        }
    }
}

test "M12 four-byte binary list counts and fixed-width scalars fail at every missing byte" {
    const headers = [_][]const u8{
        "ply\nformat binary_little_endian 1.0\nelement face 1\nproperty list uint uint indices\nend_header\n",
        "ply\nformat binary_big_endian 1.0\nelement face 1\nproperty list uint uint indices\nend_header\n",
        "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty double x\nend_header\n",
        "ply\nformat binary_big_endian 1.0\nelement vertex 1\nproperty double x\nend_header\n",
    };
    const bodies = [_][]const u8{
        "\x02\x00\x00\x00\x07\x00\x00\x00\x08\x00\x00\x00",
        "\x00\x00\x00\x02\x00\x00\x00\x07\x00\x00\x00\x08",
        "\x00\x00\x00\x00\x00\x00\xf0\x3f",
        "\x3f\xf0\x00\x00\x00\x00\x00\x00",
    };
    for (headers, bodies) |header, body| {
        const fixture: Fixture = .{ .header = header, .body = body, .cuts = &.{} };
        const bytes = try sourceFor(fixture, "");
        defer std.testing.allocator.free(bytes);
        for (0..body.len) |offset| {
            inline for (.{ Fault.eof, Fault.read_failed }) |fault| {
                var source = FaultReader.init(bytes, .{
                    .fragments = &.{ 1, 3, 2 },
                    .cutoff = header.len + offset,
                    .fault = fault,
                });
                var parser = try Parser.init(std.testing.allocator, std.testing.io, source.reader(), .{
                    .chunk_size = 64, .memory_budget = 2 * 1024 * 1024,
                });
                defer parser.deinit();
                const outcome = parser.next();
                if (outcome) |maybe| {
                    if (maybe) |value| {
                        var batch = value;
                        batch.release();
                    }
                    return error.PartialBinaryRecordPublished;
                } else |err| {
                    const diag = parser.lastDiagnostic() orelse return error.MissingDiagnostic;
                    try std.testing.expectEqual(err, diag.code.?);
                    try std.testing.expectEqual(
                        if (fault == .read_failed) Diagnostic.Category.reader else Diagnostic.Category.truncation,
                        diag.category,
                    );
                    try std.testing.expectEqual(Parser.State.failed, parser.state);
                }
                try std.testing.expect(source.position <= header.len + offset);
                try assertAccounting(&parser);
            }
        }
    }
}

test "M12 reader fails immediately after declared body but parser never touches it" {
    for (fixtures) |fixture| {
        const bytes = try sourceFor(fixture, "TRAILER");
        defer std.testing.allocator.free(bytes);
        var source = FaultReader.init(bytes, .{
            .fragments = &.{1},
            .cutoff = fixture.header.len + fixture.body.len,
            .fault = .read_failed,
        });
        var parser = try Parser.init(std.testing.allocator, std.testing.io, source.reader(), .{ .chunk_size = 64 });
        defer parser.deinit();
        var seen: usize = 0;
        while (try parser.next()) |value| {
            var batch = value;
            defer batch.release();
            try checkBatch(&batch, &seen);
        }
        try std.testing.expectEqual(@as(usize, 2), seen);
        try std.testing.expectEqual(Parser.State.completed, parser.state);
        try std.testing.expect(source.position <= fixture.header.len + fixture.body.len);
    }
}

test "M12 initialization allocation failures clean up all three encodings" {
    for (fixtures) |fixture| {
        const bytes = try sourceFor(fixture, "");
        defer std.testing.allocator.free(bytes);
        var reached_success = false;
        for (0..160) |index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
            var reader: std.Io.Reader = .fixed(bytes);
            if (Parser.init(failing.allocator(), std.testing.io, &reader, .{
                .chunk_size = 64,
                .memory_budget = 2 * 1024 * 1024,
            })) |value| {
                var parser = value;
                parser.deinit();
                reached_success = true;
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            if (reached_success) break;
        }
        try std.testing.expect(reached_success);
    }
}

test "M12 body allocation failure sweep preserves ownership and never publishes a partial batch" {
    var failures: usize = 0;
    for (fixtures) |fixture| {
        const bytes = try sourceFor(fixture, "");
        defer std.testing.allocator.free(bytes);
        for (0..90) |offset| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var reader: std.Io.Reader = .fixed(bytes);
            var parser = try Parser.init(failing.allocator(), std.testing.io, &reader, .{
                .chunk_size = 64, .memory_budget = 2 * 1024 * 1024,
            });
            var seen: usize = 0;
            var failed_once = false;
            failing.fail_index = failing.alloc_index + offset;
            for (0..12) |_| {
                const result = parser.next() catch |err| {
                    try std.testing.expect(err == error.OutOfMemory or err == error.BatchCapacityUnavailable);
                    try std.testing.expect(!failed_once);
                    failed_once = true;
                    failures += 1;
                    const diag = parser.lastDiagnostic() orelse return error.MissingDiagnostic;
                    try std.testing.expectEqual(err, diag.code.?);
                    try assertAccounting(&parser);
                    failing.fail_index = std.math.maxInt(usize);
                    if (parser.state == .failed) break;
                    continue;
                };
                if (result) |value| {
                    var batch = value;
                    defer batch.release();
                    try checkBatch(&batch, &seen);
                } else break;
            }
            if (parser.state != .failed) try std.testing.expectEqual(@as(usize, 2), seen);
            try assertAccounting(&parser);
            try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
            parser.deinit();
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
    try std.testing.expect(failures > 0);
}
