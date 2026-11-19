//! Phase 11 M16: comparable, warm-memory end-to-end performance samples.
//! `zig build bench-phase11 -Doptimize=ReleaseFast 2> phase11.csv`
//! Dataset creation is outside the timed Parser.init -> next -> deinit path.
//! Every run validates exact record and list counts and a commutative digest.
const std = @import("std");
const zply = @import("zply");

const record_count: usize = 250_000;
const warmup_rounds: usize = 2;
const measured_rounds: usize = 9;
const normal_chunk: usize = 256 * 1024;
const small_chunk: usize = 8 * 1024;
const memory_budget: usize = 16 * 1024 * 1024;

const Kind = enum {
    binary_xyz_f32,
    binary_xyz_f64,
    binary_xyzrgb,
    binary_polygons_le,
    binary_polygons_be,
    ascii_xyz,
    ascii_polygons,

    fn isPolygon(self: Kind) bool {
        return switch (self) {
            .binary_polygons_le, .binary_polygons_be, .ascii_polygons => true,
            else => false,
        };
    }
};

const Mode = enum {
    single_ordered,
    threaded_ordered,
    threaded_unordered,
    single_small_chunk,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .single_ordered => "single-ordered",
            .threaded_ordered => "threaded-ordered",
            .threaded_unordered => "threaded-unordered",
            .single_small_chunk => "single-small-chunk",
        };
    }

    fn chunk(self: Mode) usize {
        return if (self == .single_small_chunk) small_chunk else normal_chunk;
    }
};

const modes = [_]Mode{ .single_ordered, .threaded_ordered, .threaded_unordered, .single_small_chunk };
const workloads = [_]Kind{ .binary_xyz_f32, .binary_xyz_f64, .binary_xyzrgb, .binary_polygons_le, .binary_polygons_be, .ascii_xyz, .ascii_polygons };

fn mix(initial: u64) u64 {
    var x = initial;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

const Digest = struct {
    sum: u64 = 0,
    xor_value: u64 = 0,

    fn add(self: *Digest, hash: u64) void {
        const value = mix(hash);
        self.sum +%= value;
        self.xor_value ^= value;
    }

    fn eql(self: Digest, other: Digest) bool {
        return self.sum == other.sum and self.xor_value == other.xor_value;
    }
};

fn hashXYZ32(index: usize, x: u32, y: u32, zz: u32, rgb: ?[3]u8) u64 {
    var h = mix(@as(u64, @intCast(index))) ^ mix(x) ^ mix(y +% 0x9e3779b9) ^ mix(zz +% 0x85ebca6b);
    if (rgb) |colors| {
        h ^= mix((@as(u64, colors[0]) << 16) | (@as(u64, colors[1]) << 8) | colors[2]);
    }
    return h;
}

fn hashXYZ64(index: usize, x: u64, y: u64, zz: u64) u64 {
    return mix(@as(u64, @intCast(index))) ^ mix(x) ^ mix(y +% 0x9e3779b97f4a7c15) ^ mix(zz +% 0xc2b2ae3d27d4eb4f);
}

fn hashPolygon(index: usize, values: []const i32, material: u16) u64 {
    var h = mix(@as(u64, @intCast(index))) ^ mix(@as(u64, @intCast(values.len))) ^ mix(material);
    for (values, 0..) |value, j| {
        h ^= mix((@as(u64, @intCast(j)) << 32) | @as(u32, @bitCast(value)));
    }
    return h;
}

fn polygonCount(index: usize) usize {
    return switch (index % 4) {
        0 => 0,
        1 => 3,
        2 => 4,
        else => 5,
    };
}

fn xyz32(index: usize) [3]u32 {
    const id: u32 = @intCast(index);
    return .{
        0x3f800000 | (id & 0x007fffff),
        0x40000000 | ((id *% 7) & 0x007fffff),
        0x40400000 | ((id *% 13) & 0x007fffff),
    };
}

fn xyz64(index: usize) [3]u64 {
    const id: u64 = @intCast(index);
    return .{
        0x3ff0000000000000 | id,
        0x4000000000000000 | (id *% 7),
        0x4008000000000000 | (id *% 13),
    };
}

fn rgbFor(index: usize) [3]u8 {
    return .{ @truncate(index), @truncate(index *% 7), @truncate(index *% 13) };
}

const Input = struct {
    bytes: []u8,
    body_bytes: usize,
    list_items: usize,
    kind: Kind,
    expected: Digest,

    fn deinit(self: Input, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn createInput(allocator: std.mem.Allocator, kind: Kind) !Input {
    const format: []const u8 = switch (kind) {
        .ascii_xyz, .ascii_polygons => "ascii",
        .binary_polygons_be => "binary_big_endian",
        else => "binary_little_endian",
    };
    const properties: []const u8 = switch (kind) {
        .binary_xyz_f64 => "property double x\nproperty double y\nproperty double z\n",
        .binary_xyzrgb => "property float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\n",
        .binary_polygons_le, .binary_polygons_be, .ascii_polygons => "property list uchar int indices\nproperty ushort material\n",
        else => "property float x\nproperty float y\nproperty float z\n",
    };
    const element = if (kind.isPolygon()) "face" else "vertex";
    const header = try std.fmt.allocPrint(allocator,
        "ply\nformat {s} 1.0\nelement {s} {d}\n{s}end_header\n",
        .{ format, element, record_count, properties },
    );
    defer allocator.free(header);

    const xyz_line = "1.25 -2.5 3.75\n";
    const polygon_lines = [_][]const u8{
        "0 7\n",
        "3 1 2 3 7\n",
        "4 1 2 3 4 7\n",
        "5 1 2 3 4 5 7\n",
    };
    var body_bytes: usize = 0;
    var list_items: usize = 0;
    for (0..record_count) |index| {
        const n = polygonCount(index);
        body_bytes += switch (kind) {
            .binary_xyz_f32 => 12,
            .binary_xyz_f64 => 24,
            .binary_xyzrgb => 15,
            .binary_polygons_le, .binary_polygons_be => 1 + n * 4 + 2,
            .ascii_xyz => xyz_line.len,
            .ascii_polygons => polygon_lines[index % 4].len,
        };
        if (kind.isPolygon()) list_items += n;
    }
    const bytes = try allocator.alloc(u8, header.len + body_bytes);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);
    var cursor: usize = header.len;
    var expected: Digest = .{};
    const values = [_]i32{ 1, 2, 3, 4, 5 };
    const endian: std.builtin.Endian = if (kind == .binary_polygons_be) .big else .little;
    for (0..record_count) |index| {
        switch (kind) {
            .binary_xyz_f32, .binary_xyzrgb => {
                const xyz = xyz32(index);
                for (xyz) |bits| {
                    std.mem.writeInt(u32, bytes[cursor..][0..4], bits, .little);
                    cursor += 4;
                }
                const colors: ?[3]u8 = if (kind == .binary_xyzrgb) rgbFor(index) else null;
                if (colors) |rgb| {
                    @memcpy(bytes[cursor..][0..3], &rgb);
                    cursor += 3;
                }
                expected.add(hashXYZ32(index, xyz[0], xyz[1], xyz[2], colors));
            },
            .binary_xyz_f64 => {
                const xyz = xyz64(index);
                for (xyz) |bits| {
                    std.mem.writeInt(u64, bytes[cursor..][0..8], bits, .little);
                    cursor += 8;
                }
                expected.add(hashXYZ64(index, xyz[0], xyz[1], xyz[2]));
            },
            .binary_polygons_le, .binary_polygons_be => {
                const n = polygonCount(index);
                bytes[cursor] = @intCast(n);
                cursor += 1;
                for (values[0..n]) |item| {
                    std.mem.writeInt(i32, bytes[cursor..][0..4], item, endian);
                    cursor += 4;
                }
                std.mem.writeInt(u16, bytes[cursor..][0..2], 7, endian);
                cursor += 2;
                expected.add(hashPolygon(index, values[0..n], 7));
            },
            .ascii_xyz => {
                @memcpy(bytes[cursor..][0..xyz_line.len], xyz_line);
                cursor += xyz_line.len;
                expected.add(hashXYZ32(index, @bitCast(@as(f32, 1.25)), @bitCast(@as(f32, -2.5)), @bitCast(@as(f32, 3.75)), null));
            },
            .ascii_polygons => {
                const line = polygon_lines[index % 4];
                @memcpy(bytes[cursor..][0..line.len], line);
                cursor += line.len;
                expected.add(hashPolygon(index, values[0..polygonCount(index)], 7));
            },
        }
    }
    std.debug.assert(cursor == bytes.len);
    return .{ .bytes = bytes, .body_bytes = body_bytes, .list_items = list_items, .kind = kind, .expected = expected };
}

const Sample = struct {
    nanoseconds: i96,
    batches: usize,
    peak_bytes: usize,
    native_submissions: u64,
    inline_decodes: u64,
    max_active: usize,
};

fn runOnce(allocator: std.mem.Allocator, io: std.Io, input: Input, mode: Mode) !Sample {
    var reader: std.Io.Reader = .fixed(input.bytes);
    const start = std.Io.Clock.awake.now(io);
    var parser = try zply.Parser.init(allocator, io, &reader, .{
        .chunk_size = mode.chunk(),
        .memory_budget = memory_budget,
        .preserve_order = mode != .threaded_unordered,
    });
    errdefer parser.deinit();
    var digest: Digest = .{};
    var records: usize = 0;
    var items: usize = 0;
    var batches: usize = 0;
    while (try parser.next()) |result| {
        var batch = result;
        defer batch.release();
        const info = batch.info();
        const start_record: usize = @intCast(info.first_record);
        if (info.element_index != 0 or start_record + info.record_count > record_count) return error.InvalidBatchMetadata;
        if (input.kind.isPolygon()) {
            const lists = try batch.listColumn(0);
            const material = try batch.typedColumn(u16, 1);
            if (material.len != info.record_count) return error.InvalidColumnShape;
            for (material, 0..) |tag, row| {
                const values = lists.row(row).?.i32;
                digest.add(hashPolygon(start_record + row, values, tag));
                items += values.len;
            }
        } else if (input.kind == .binary_xyz_f64) {
            const x = try batch.typedColumn(f64, 0);
            const y = try batch.typedColumn(f64, 1);
            const zz = try batch.typedColumn(f64, 2);
            if (x.len != info.record_count or y.len != x.len or zz.len != x.len) return error.InvalidColumnShape;
            for (x, y, zz, 0..) |vx, vy, vz, row| {
                digest.add(hashXYZ64(start_record + row, @bitCast(vx), @bitCast(vy), @bitCast(vz)));
            }
        } else {
            const x = try batch.typedColumn(f32, 0);
            const y = try batch.typedColumn(f32, 1);
            const zz = try batch.typedColumn(f32, 2);
            if (x.len != info.record_count or y.len != x.len or zz.len != x.len) return error.InvalidColumnShape;
            if (input.kind == .binary_xyzrgb) {
                const r = try batch.typedColumn(u8, 3);
                const g = try batch.typedColumn(u8, 4);
                const b = try batch.typedColumn(u8, 5);
                if (r.len != x.len or g.len != x.len or b.len != x.len) return error.InvalidColumnShape;
                for (x, y, zz, r, g, b, 0..) |vx, vy, vz, vr, vg, vb, row| {
                    digest.add(hashXYZ32(start_record + row, @bitCast(vx), @bitCast(vy), @bitCast(vz), .{ vr, vg, vb }));
                }
            } else {
                for (x, y, zz, 0..) |vx, vy, vz, row| {
                    digest.add(hashXYZ32(start_record + row, @bitCast(vx), @bitCast(vy), @bitCast(vz), null));
                }
            }
        }
        records += info.record_count;
        batches += 1;
    }
    const memory = parser.memoryStats();
    const execution = parser.executionStats();
    parser.deinit();
    // Do not report a "threaded" speedup if native submission silently
    // fell back to synchronous execution for the entire workload.
    if ((mode == .threaded_ordered or mode == .threaded_unordered) and
        execution.native_submissions == 0) return error.NativeConcurrencyInactive;
    const end = std.Io.Clock.awake.now(io);
    if (memory.peak_total_bytes > memory_budget or records != record_count or items != input.list_items or !digest.eql(input.expected)) {
        std.debug.print("INVALID BENCHMARK workload={s} mode={s} records={d}/{d} items={d}/{d}\n", .{
            @tagName(input.kind), mode.label(), records, record_count, items, input.list_items,
        });
        return error.IncorrectDecodedOutput;
    }
    const elapsed = start.durationTo(end).nanoseconds;
    if (elapsed <= 0) return error.InvalidMeasurement;
    return .{
        .nanoseconds = elapsed,
        .batches = batches,
        .peak_bytes = memory.peak_total_bytes,
        .native_submissions = execution.native_submissions,
        .inline_decodes = execution.inline_decodes,
        .max_active = execution.max_active_decodes,
    };
}

fn percentile(sorted: []const i96, percent: usize) i96 {
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[@max(@as(usize, 1), rank) - 1];
}

fn report(allocator: std.mem.Allocator, single: *std.Io.Threaded, threaded: *std.Io.Threaded, input: Input) !void {
    var samples: [modes.len][measured_rounds]i96 = undefined;
    var last: [modes.len]Sample = undefined;
    var peaks: [modes.len]usize = @splat(0);
    for (0..warmup_rounds + measured_rounds) |round| {
        for (0..modes.len) |slot| {
            // Rotate execution order to avoid systematic warm-cache bias.
            const index = (round + slot) % modes.len;
            const mode = modes[index];
            const io = if (mode == .threaded_ordered or mode == .threaded_unordered) threaded.io() else single.io();
            const result = try runOnce(allocator, io, input, mode);
            if (round >= warmup_rounds) {
                samples[index][round - warmup_rounds] = result.nanoseconds;
                last[index] = result;
                peaks[index] = @max(peaks[index], result.peak_bytes);
            }
        }
    }
    for (modes, 0..) |mode, index| {
        std.mem.sortUnstable(i96, samples[index][0..], {}, std.sort.asc(i96));
        const sorted = samples[index][0..];
        const median = sorted[sorted.len / 2];
        const sec = @as(f64, @floatFromInt(median)) / 1e9;
        std.debug.print("{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.1},{d:.6},{d:.1},{d},{d},{d},{d},{d},{x},{x}\n", .{
            @tagName(input.kind), mode.label(), record_count, input.body_bytes, input.list_items,
            mode.chunk(), memory_budget, warmup_rounds, measured_rounds,
            median, percentile(sorted, 5), percentile(sorted, 95),
            @as(f64, @floatFromInt(record_count)) / sec,
            @as(f64, @floatFromInt(input.body_bytes)) / sec / 1e9,
            @as(f64, @floatFromInt(input.list_items)) / sec,
            peaks[index], last[index].batches, last[index].native_submissions,
            last[index].inline_decodes, last[index].max_active, input.expected.sum, input.expected.xor_value,
        });
    }
}

pub fn main(init: std.process.Init) !void {
    var single: std.Io.Threaded = .init_single_threaded;
    var threaded: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .limited(4) });
    defer threaded.deinit();

    std.debug.print("workload,mode,records,body_bytes,list_items,chunk_bytes,budget_bytes,warmups,rounds,median_ns,p05_ns,p95_ns,records_per_s,input_gbps,list_items_per_s,parser_peak_bytes,batches,native_submissions,inline_decodes,max_active,digest_sum,digest_xor\n", .{});
    for (workloads) |kind| {
        const input = try createInput(init.gpa, kind);
        defer input.deinit(init.gpa);
        try report(init.gpa, &single, &threaded, input);
    }
}
