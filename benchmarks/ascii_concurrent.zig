//! Phase 9 warm-memory executor comparison. Input generation is excluded.
//! Benchmarks the same record-aligned pipeline with single-context and
//! threaded native Io, including list preflight and ordered delivery.
const std = @import("std");
const z = @import("zply");

const runs: usize = 5;
const warmups: usize = 2;
const Kind = enum { xyz, face };
const Spec = struct { bytes: []u8, body_len: usize, count: usize, kind: Kind };

fn create(a: std.mem.Allocator, count: usize, kind: Kind) !Spec {
    const header = switch (kind) {
        .xyz => try std.fmt.allocPrint(a, "ply\nformat ascii 1.0\nelement vertex {d}\nproperty float x\nproperty float y\nproperty float z\nend_header\n", .{count}),
        .face => try std.fmt.allocPrint(a, "ply\nformat ascii 1.0\nelement face {d}\nproperty list uchar int indices\nend_header\n", .{count}),
    };
    defer a.free(header);
    const line = switch (kind) {
        .xyz => "1.25 -2.5 3.75\n",
        .face => "3 0 1 2\n",
    };
    const body_len = try std.math.mul(usize, count, line.len);
    const bytes = try a.alloc(u8, try std.math.add(usize, header.len, body_len));
    @memcpy(bytes[0..header.len], header);
    for (0..count) |i| @memcpy(bytes[header.len + i * line.len ..][0..line.len], line);
    return .{ .bytes = bytes, .body_len = body_len, .count = count, .kind = kind };
}
const Sample = struct {
    ns: i96,
    records: usize,
    batches: usize,
    peak: usize,
    checksum: f64,
    execution: z.Parser.ExecutionStats,
};

fn measure(a: std.mem.Allocator, io: std.Io, spec: Spec, ordered: bool) !Sample {
    var reader: std.Io.Reader = .fixed(spec.bytes);
    const start = std.Io.Clock.awake.now(io);
    var parser = try z.Parser.init(a, io, &reader, .{
        .chunk_size = 256 * 1024,
        .memory_budget = 16 * 1024 * 1024,
        .preserve_order = ordered,
    });
    errdefer parser.deinit();
    var count: usize = 0;
    var batches: usize = 0;
    var sum: f64 = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        switch (spec.kind) {
            .xyz => {
                const x = try batch.typedColumn(f32, 0);
                const y = try batch.typedColumn(f32, 1);
                const zz = try batch.typedColumn(f32, 2);
                for (x, y, zz) |vx, vy, vz| sum += @as(f64, vx) + @as(f64, vy) + @as(f64, vz);
            },
            .face => {
                const lists = try batch.listColumn(0);
                for (0..info.record_count) |row| {
                    for (lists.row(row).?.i32) |v| sum += @as(f64, @floatFromInt(v));
                }
            },
        }
        count += info.record_count;
        batches += 1;
    }
    const peak = parser.memoryStats().peak_total_bytes;
    const execution = parser.executionStats();
    parser.deinit();
    const end = std.Io.Clock.awake.now(io);
    return .{ .ns = start.durationTo(end).nanoseconds, .records = count, .batches = batches, .peak = peak, .checksum = sum, .execution = execution };
}

pub fn main(init: std.process.Init) !void {
    var single: std.Io.Threaded = .init_single_threaded;
    var concurrent: std.Io.Threaded = .init(init.gpa, .{});
    defer concurrent.deinit();
    std.debug.print("Phase 9 ASCII concurrent decoding: {d} warmups + {d} measured rounds\n", .{ warmups, runs });
    inline for (.{ Kind.xyz, Kind.face }) |kind| {
        const spec = try create(init.gpa, 300_000, kind);
        defer init.gpa.free(spec.bytes);
        std.debug.print("{s}: {d} records, {d} input bytes\n", .{ @tagName(kind), spec.count, spec.body_len });
        const choices = [_]struct { name: []const u8, io: std.Io, ordered: bool }{
            .{ .name = "single ordered", .io = single.io(), .ordered = true },
            .{ .name = "threaded ordered", .io = concurrent.io(), .ordered = true },
            .{ .name = "threaded unordered", .io = concurrent.io(), .ordered = false },
        };
        for (choices) |choice| {
            for (0..warmups) |_| {
                const s = try measure(init.gpa, choice.io, spec, choice.ordered);
                if (s.records != spec.count) return error.RecordCountMismatch;
            }
            var times: [runs]i96 = undefined;
            var last: Sample = undefined;
            for (&times) |*t| {
                last = try measure(init.gpa, choice.io, spec, choice.ordered);
                t.* = last.ns;
                if (last.records != spec.count or last.checksum != @as(f64, @floatFromInt(spec.count)) * (if (kind == .xyz) @as(f64, 2.5) else @as(f64, 3))) return error.IncorrectOutput;
            }
            std.mem.sortUnstable(i96, &times, {}, std.sort.asc(i96));
            const sec = @as(f64, @floatFromInt(times[runs / 2])) / 1e9;
            std.debug.print("  {s}: median={d:.3} ms {d:.2} Mrec/s {d:.3} GB/s batches={d} peak={d} accepted={d} inline={d} max_active={d}\n", .{
                choice.name,                                        sec * 1e3,                     @as(f64, @floatFromInt(spec.count)) / sec / 1e6,
                @as(f64, @floatFromInt(spec.body_len)) / sec / 1e9, last.batches,                  last.peak,
                last.execution.native_submissions,                  last.execution.inline_decodes, last.execution.max_active_decodes,
            });
        }
    }
}
