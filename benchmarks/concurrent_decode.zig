//! Phase 7: reproducible warm-memory, end-to-end Parser.next() benchmark.
//! Zig 0.17.0. The Io implementation controls scheduling; zply has no worker API.
//!
//! Measures the full Parser.init -> Parser.next -> Parser.deinit lifecycle,
//! including column traversal and an order-independent checksum.
//! Does not measure input generation or physical file I/O.
const std = @import("std");
const z = @import("zply");

const chunk_size: usize = 256 * 1024;
const warmup_rounds: usize = 3;
const measured_rounds: usize = 15;
const dataset_sizes = [_]usize{ 500_000, 3_000_000, 10_000_000 };
// Add 100_000_000 above for a 1.2 GB input (plus parser buffers).

// Executor capacity belongs to the caller's std.Io implementation, not
// Parser.Options. Each threaded mode measures a separate Threaded instance.
const capacities = [_]usize{ 2, 4, 8 };
const Mode = enum(u8) {
    single_ordered,
    ordered_2,
    ordered_4,
    ordered_8,
    unordered_2,
    unordered_4,
    unordered_8,

    fn name(self: Mode) []const u8 {
        return switch (self) {
            .single_ordered => "single ordered",
            .ordered_2 => "threaded 2 ordered",
            .ordered_4 => "threaded 4 ordered",
            .ordered_8 => "threaded 8 ordered",
            .unordered_2 => "threaded 2 unordered",
            .unordered_4 => "threaded 4 unordered",
            .unordered_8 => "threaded 8 unordered",
        };
    }
    fn executorIndex(self: Mode) ?usize {
        return switch (self) {
            .single_ordered => null,
            .ordered_2, .unordered_2 => 0,
            .ordered_4, .unordered_4 => 1,
            .ordered_8, .unordered_8 => 2,
        };
    }
    fn preserveOrder(self: Mode) bool {
        return switch (self) {
            .unordered_2, .unordered_4, .unordered_8 => false,
            else => true,
        };
    }
};
const modes = [_]Mode{
    .single_ordered, .ordered_2, .ordered_4, .ordered_8,
    .unordered_2, .unordered_4, .unordered_8,
};

// Two commutative accumulators, with different weights for x/y/z.
// The checksum is insensitive to the order in which batches are returned.
const Digest = struct {
    sum: u64 = 0,
    xor_value: u64 = 0,

    fn add(self: *Digest, x: u32, y: u32, zz: u32) void {
        const k = (@as(u64, x) *% 0x9e3779b185ebca87) ^
            (@as(u64, y) *% 0xc2b2ae3d27d4eb4f) ^
            (@as(u64, zz) *% 0x165667b19e3779f9);
        const h = k ^ (k >> 33);
        self.sum +%= h;
        self.xor_value ^= h;
    }

    fn eql(self: Digest, other: Digest) bool {
        return self.sum == other.sum and self.xor_value == other.xor_value;
    }
};

const Input = struct {
    bytes: []u8,
    body_size: usize,
    expected: Digest,

    fn init(gpa: std.mem.Allocator, count: usize) !Input {
        if (count > std.math.maxInt(u32)) return error.TooManyRecords;
        const header = try gpa.print(
            "ply\nformat binary_little_endian 1.0\nelement vertex {d}\n" ++
                "property float x\nproperty float y\nproperty float z\nend_header\n",
            .{count},
        );
        defer gpa.free(header);

        const body_size = try std.math.mul(usize, count, 12);
        const bytes = try gpa.alloc(u8, header.len + body_size);
        @memcpy(bytes[0..header.len], header);

        var expected: Digest = .{};
        for (0..count) |i| {
            const id: u32 = @intCast(i);
            // Exactly representable, finite float bit patterns; x/y encode
            // the global record id, and z is a record-specific cross-check.
            const x: u32 = 0x3f800000 | (id & 0x007fffff);
            const y: u32 = 0x40000000 | ((id >> 23) & 0x007fffff);
            const zz: u32 = 0x3f000000 | ((id *% 0x9e3779b9) & 0x007fffff);
            const off = header.len + i * 12;
            writeU32Le(bytes[off..][0..4], x);
            writeU32Le(bytes[off + 4 ..][0..4], y);
            writeU32Le(bytes[off + 8 ..][0..4], zz);
            expected.add(x, y, zz);
        }
        return .{ .bytes = bytes, .body_size = body_size, .expected = expected };
    }

    fn deinit(self: Input, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }
};

fn writeU32Le(out: []u8, x: u32) void {
    out[0] = @truncate(x);
    out[1] = @truncate(x >> 8);
    out[2] = @truncate(x >> 16);
    out[3] = @truncate(x >> 24);
}

const Sample = struct {
    nanoseconds: i96,
    decoded_records: usize,
    batches: usize,
    peak_parser_bytes: usize,
    execution: z.Parser.ExecutionStats,
    digest: Digest,
};

fn runOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    preserve_order: bool,
) !Sample {
    var reader: std.Io.Reader = .fixed(source);
    var options: z.Options = .{};
    options.chunk_size = chunk_size;
    options.preserve_order = preserve_order;

    const start = std.Io.Clock.awake.now(io);
    var parser = try z.Parser.init(gpa, io, &reader, options);
    errdefer parser.deinit();

    var digest: Digest = .{};
    var decoded_records: usize = 0;
    var batches: usize = 0;

    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();

        const xs = try batch.typedColumn(f32, 0);
        const ys = try batch.typedColumn(f32, 1);
        const zs = try batch.typedColumn(f32, 2);
        if (xs.len != ys.len or xs.len != zs.len) {
            return error.ColumnLengthMismatch;
        }

        for (xs, ys, zs) |x, y, zz| {
            digest.add(@bitCast(x), @bitCast(y), @bitCast(zz));
        }
        decoded_records += xs.len;
        batches += 1;
    }
    const stats = parser.memoryStats();
    const execution = parser.executionStats();
    parser.deinit();
    const end = std.Io.Clock.awake.now(io);
    return .{
        .nanoseconds = start.durationTo(end).nanoseconds,
        .decoded_records = decoded_records,
        .batches = batches,
        .peak_parser_bytes = stats.peak_total_bytes,
        .execution = execution,
        .digest = digest,
    };
}

fn checkedRun(
    gpa: std.mem.Allocator,
    single: *std.Io.Threaded,
    executors: *[capacities.len]std.Io.Threaded,
    input: Input,
    count: usize,
    mode: Mode,
) !Sample {
    const io = if (mode.executorIndex()) |index| executors[index].io() else single.io();
    const sample = try runOnce(gpa, io, input.bytes, mode.preserveOrder());
    if (sample.decoded_records != count or !sample.digest.eql(input.expected)) {
        std.debug.print(
            "CORRUPT {s}: records={d}/{d} digest={x}:{x} expected={x}:{x}\n",
            .{ mode.name(), sample.decoded_records, count, sample.digest.sum, sample.digest.xor_value, input.expected.sum, input.expected.xor_value },
        );
        return error.DecodedDataMismatch;
    }
    if (sample.nanoseconds <= 0) return error.InvalidClockMeasurement;
    return sample;
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// Nearest-rank percentile of a sorted slice; percent in [1, 100].
fn percentile(sorted: []const i96, percent: usize) i96 {
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[@max(@as(usize, 1), rank) - 1];
}

fn benchSize(
    gpa: std.mem.Allocator,
    single: *std.Io.Threaded,
    executors: *[capacities.len]std.Io.Threaded,
    count: usize,
) !void {
    const input = try Input.init(gpa, count);
    defer input.deinit(gpa);

    std.debug.print(
        "\nXYZ f32: {d} records, {d:.1} MB input, {d} KiB chunks\n",
        .{ count, @as(f64, @floatFromInt(input.body_size)) / 1e6, chunk_size / 1024 },
    );

    var times: [modes.len][measured_rounds]i96 = undefined;
    var last: [modes.len]Sample = undefined;
    var max_peaks: [modes.len]usize = @splat(0);

    // Rotating order prevents one mode from always going first or last.
    // Warmups also allow the Threaded implementation to initialize its pool.
    for (0..warmup_rounds) |round| {
        for (0..modes.len) |slot| {
            const index = (round + slot) % modes.len;
            _ = try checkedRun(gpa, single, executors, input, count, modes[index]);
        }
    }
    for (0..measured_rounds) |round| {
        for (0..modes.len) |slot| {
            const index = (round + slot) % modes.len;
            const result = try checkedRun(gpa, single, executors, input, count, modes[index]);
            times[index][round] = result.nanoseconds;
            last[index] = result;
            max_peaks[index] = @max(max_peaks[index], result.peak_parser_bytes);
        }
    }

    var medians: [modes.len]i96 = undefined;
    for (modes, 0..) |mode, index| {
        std.mem.sortUnstable(i96, times[index][0..], {}, std.sort.asc(i96));
        const sorted = times[index][0..];
        const median = sorted[sorted.len / 2];
        medians[index] = median;
        const seconds = @as(f64, @floatFromInt(median)) / 1e9;
        std.debug.print(
            "  {s}: median={d:.3} ms p05={d:.3} ms p95={d:.3} ms " ++
                "{d:.2} Mrec/s {d:.2} GB/s batches={d} parser_peak={d} " ++
                "accepted={d} rejected={d} inline={d} max_inflight={d} max_active={d} digest={x}:{x}\n",
            .{
                mode.name(),                  ms(median),                                     ms(percentile(sorted, 5)),
                ms(percentile(sorted, 95)),   @as(f64, @floatFromInt(count)) / seconds / 1e6, @as(f64, @floatFromInt(input.body_size)) / seconds / 1e9,
                last[index].batches,          max_peaks[index],
                last[index].execution.native_submissions, last[index].execution.rejected_submissions,
                last[index].execution.inline_decodes, last[index].execution.max_inflight,
                last[index].execution.max_active_decodes,
                last[index].digest.sum, last[index].digest.xor_value,
            },
        );
    }

    const single_ns = @as(f64, @floatFromInt(medians[0]));
    inline for (capacities, 0..) |capacity, i| {
        const ordered_ns = @as(f64, @floatFromInt(medians[1 + i]));
        const unordered_ns = @as(f64, @floatFromInt(medians[4 + i]));
        std.debug.print(
            "  executor limit {d}: speedup vs single ordered={d:.2}x unordered={d:.2}x; " ++
                "unordered vs ordered={d:.2}x\n",
            .{ capacity, single_ns / ordered_ns, single_ns / unordered_ns, ordered_ns / unordered_ns },
        );
    }
}

pub fn main(init: std.process.Init) !void {
    var single: std.Io.Threaded = .init_single_threaded;
    var executors: [capacities.len]std.Io.Threaded = undefined;
    for (capacities, 0..) |limit, i| {
        executors[i] = .init(init.gpa, .{ .concurrent_limit = .limited(limit) });
    }
    defer {
        for (&executors) |*executor| executor.deinit();
    }

    std.debug.print(
        "Phase 7 warm-memory executor scaling benchmark: " ++
            "{d} warmup + {d} measured rounds; median/p05/p95 latency\n" ++
            "Io: single ordered | threaded 2/4/8 ordered | threaded 2/4/8 unordered\n" ++
            "Executor limits are external; inline fallback may increase max_active above a limit.\n" ++
            "Timing: Parser.init -> next() -> deinit + checksum; excludes source generation\n",
        .{ warmup_rounds, measured_rounds },
    );
    for (dataset_sizes) |count| {
        try benchSize(init.gpa, &single, &executors, count);
    }
}
