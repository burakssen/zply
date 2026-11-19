//! Phase 8 warm-memory sequential ASCII decoding benchmark.
//! Excludes source generation; reports typed records/s and source MB/s.
const std = @import("std");
const z = @import("zply");

const warmups: usize = 2;
const rounds: usize = 7;
const sizes = [_]usize{ 10_000, 500_000, 3_000_000 };

const Input = struct {
    bytes: []u8,
    body_size: usize,

    fn init(a: std.mem.Allocator, count: usize) !Input {
        const h = try a.print("ply\nformat ascii 1.0\nelement vertex {d}\n" ++
            "property float x\nproperty float y\nproperty float z\nend_header\n", .{count});
        defer a.free(h);
        const line = "1.25 -2.5 3.75\n";
        const body_len = try std.math.mul(usize, count, line.len);
        const bytes = try a.alloc(u8, h.len + body_len);
        @memcpy(bytes[0..h.len], h);
        for (0..count) |i| @memcpy(bytes[h.len + i * line.len ..][0..line.len], line);
        return .{ .bytes = bytes, .body_size = body_len };
    }
    fn deinit(self: Input, a: std.mem.Allocator) void { a.free(self.bytes); }
};

const Sample = struct { ns: i96, records: usize, batches: usize, peak: usize, checksum: f64 };

fn once(a: std.mem.Allocator, io: std.Io, bytes: []const u8) !Sample {
    var reader: std.Io.Reader = .fixed(bytes);
    const start = std.Io.Clock.awake.now(io);
    var parser = try z.Parser.init(a, io, &reader, .{ .chunk_size = 256 * 1024, .memory_budget = 16 * 1024 * 1024 });
    errdefer parser.deinit();
    var count: usize = 0;
    var batches: usize = 0;
    var sum: f64 = 0;
    while (try parser.next()) |v| {
        var batch = v;
        defer batch.release();
        const x = try batch.typedColumn(f32, 0);
        const y = try batch.typedColumn(f32, 1);
        const zz = try batch.typedColumn(f32, 2);
        for (x, y, zz) |a0, b0, c0| sum += @as(f64, a0) + @as(f64, b0) + @as(f64, c0);
        count += x.len;
        batches += 1;
    }
    const peak = parser.memoryStats().peak_total_bytes;
    parser.deinit();
    const end = std.Io.Clock.awake.now(io);
    return .{ .ns = start.durationTo(end).nanoseconds, .records = count, .batches = batches, .peak = peak, .checksum = sum };
}

pub fn main(init: std.process.Init) !void {
    var single: std.Io.Threaded = .init_single_threaded;
    std.debug.print("Phase 8 ASCII warm-memory Parser.init -> next() -> deinit; {d} warmups + {d} rounds\n", .{ warmups, rounds });
    for (sizes) |count| {
        const source = try Input.init(init.gpa, count);
        defer source.deinit(init.gpa);
        for (0..warmups) |_| {
            const sample = try once(init.gpa, single.io(), source.bytes);
            if (sample.records != count or sample.checksum != 2.5 * @as(f64, @floatFromInt(count))) return error.InvalidResult;
        }
        var samples: [rounds]i96 = undefined;
        var last: Sample = undefined;
        for (&samples) |*n| {
            last = try once(init.gpa, single.io(), source.bytes);
            n.* = last.ns;
            if (last.records != count or last.checksum != 2.5 * @as(f64, @floatFromInt(count))) return error.InvalidResult;
        }
        std.mem.sortUnstable(i96, &samples, {}, std.sort.asc(i96));
        const sec = @as(f64, @floatFromInt(samples[rounds / 2])) / 1e9;
        std.debug.print("  {d} records: median={d:.3} ms, {d:.2} Mrec/s, {d:.2} GB/s, batches={d}, peak={d} bytes\n", .{
            count, sec * 1e3, @as(f64, @floatFromInt(count)) / sec / 1e6,
            @as(f64, @floatFromInt(source.body_size)) / sec / 1e9, last.batches, last.peak,
        });
    }
}
