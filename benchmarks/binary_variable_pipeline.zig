//! Phase 10 variable-width binary PLY: sequential structural scanning versus
//! complete typed Parser.next() throughput. Generation is outside timing.
//! Run with: zig build bench-binary-variable -Doptimize=ReleaseFast
const std = @import("std");
const internals = @import("zply_internals");
// Keep structural scanning and Parser.next() in one Zig module tree.
// Importing the same source file through both `zply` and `zply_internals`
// causes a duplicate-module ownership error on Zig 0.17.1.

const warmups: usize = 2;
const rounds: usize = 5;
const Count: usize = 300_000;
const Kind = enum { triangles, mixed_polygons };
const Spec = struct {
    bytes: []u8,
    header_len: usize,
    body_len: usize,
    record_count: usize,
    item_count: usize,
    checksum: u64,
    endian: std.builtin.Endian,
};

fn make(a: std.mem.Allocator, kind: Kind, endian: std.builtin.Endian) !Spec {
    const enc = if (endian == .little) "binary_little_endian" else "binary_big_endian";
    const header = try std.fmt.allocPrint(a,
        "ply\nformat {s} 1.0\nelement face {d}\nproperty list uchar int indices\nend_header\n",
        .{ enc, Count },
    );
    defer a.free(header);
    var payload_size: usize = 0;
    var total_items: usize = 0;
    var checksum: u64 = 0;
    for (0..Count) |i| {
        const n: usize = if (kind == .triangles) 3 else switch (i % 4) {
            0 => 3,
            1 => 4,
            2 => 5,
            else => 0,
        };
        payload_size += 1 + n * 4;
        total_items += n;
        checksum += @as(u64, @intCast(n * (n + 1) / 2));
    }
    const bytes = try a.alloc(u8, header.len + payload_size);
    @memcpy(bytes[0..header.len], header);
    var cursor = header.len;
    for (0..Count) |i| {
        const n: usize = if (kind == .triangles) 3 else switch (i % 4) {
            0 => 3,
            1 => 4,
            2 => 5,
            else => 0,
        };
        bytes[cursor] = @intCast(n);
        cursor += 1;
        for (0..n) |j| {
            std.mem.writeInt(i32, bytes[cursor..][0..4], @intCast(j + 1), endian);
            cursor += 4;
        }
    }
    std.debug.assert(cursor == bytes.len);
    return .{
        .bytes = bytes, .header_len = header.len, .body_len = payload_size,
        .record_count = Count, .item_count = total_items,
        .checksum = checksum, .endian = endian,
    };
}

const Sample = struct {
    nanoseconds: i96,
    records: usize,
    items: usize,
    checksum: u64,
    batches: usize = 0,
    peak: usize = 0,
    accepted: usize = 0,
    copied_spans: u64 = 0,
    batch_reductions: u64 = 0,
};

fn measureScan(a: std.mem.Allocator, io: std.Io, spec: Spec) !Sample {
    const properties = [_]internals.property.Property{
        internals.property.Property.list("indices", .u8, .i32),
    };
    const elements = [_]internals.element.Element{.{
        .name = "face", .count = spec.record_count, .properties = &properties,
    }};
    const header: internals.header.Header = .{
        .encoding = if (spec.endian == .little) .binary_little_endian else .binary_big_endian,
        .version = .{ .major = 1, .minor = 0 }, .elements = &elements,
    };
    const layouts = try internals.layout.compileSchema(a, &header);
    defer {
        for (layouts) |l| a.free(l.properties);
        a.free(layouts);
    }
    var reader: std.Io.Reader = .fixed(spec.bytes[spec.header_len..]);
    var scanner: internals.binary_variable.Reader = .{};
    defer scanner.deinit(a);
    const limits: internals.binary_boundary.Limits = .{
        .max_record_bytes = 4096,
        .max_list_items_per_record = 1024,
    };
    const start = std.Io.Clock.awake.now(io);
    var count: usize = 0;
    var items: usize = 0;
    while (count < spec.record_count) : (count += 1) {
        const record = try scanner.readRecord(a, &reader, &layouts[0], spec.endian, limits);
        items += record.total_list_items;
    }
    const end = std.Io.Clock.awake.now(io);
    return .{ .nanoseconds = start.durationTo(end).nanoseconds,
        .records = count, .items = items, .checksum = 0,
        .copied_spans = scanner.copied_spans };
}


/// Isolate the cost of bounded record-aligned staging from typed column
/// decoding, output reservation, native scheduling, and batch publication.
/// The builder counts list items during its single structural pass.
fn measureChunkAssembly(a: std.mem.Allocator, io: std.Io, spec: Spec) !Sample {
    const properties = [_]internals.property.Property{
        internals.property.Property.list("indices", .u8, .i32),
    };
    const elements = [_]internals.element.Element{.{
        .name = "face", .count = spec.record_count, .properties = &properties,
    }};
    const header: internals.header.Header = .{
        .encoding = if (spec.endian == .little) .binary_little_endian else .binary_big_endian,
        .version = .{ .major = 1, .minor = 0 }, .elements = &elements,
    };
    const layouts = try internals.layout.compileSchema(a, &header);
    defer {
        for (layouts) |l| a.free(l.properties);
        a.free(layouts);
    }
    var reader: std.Io.Reader = .fixed(spec.bytes[spec.header_len..]);
    var builder: internals.binary_chunk_builder.Builder = .{};
    defer builder.deinit(a);
    const limits: internals.binary_boundary.Limits = .{
        .max_record_bytes = 4096,
        .max_list_items_per_record = 1024,
    };
    const start = std.Io.Clock.awake.now(io);
    var count: usize = 0;
    var items: usize = 0;
    var batches: usize = 0;
    var staged_bytes: usize = 0;
    while (count < spec.record_count) {
        const chunk = (try builder.fill(
            a, &reader, &layouts[0], spec.endian, limits,
            256 * 1024, @intCast(count), @intCast(spec.record_count - count),
        )) orelse return error.UnexpectedEndOfInput;
        count += chunk.record_count;
        items += chunk.list_item_totals[0];
        staged_bytes += chunk.bytes.len;
        batches += 1;
        builder.consume();
    }
    const end = std.Io.Clock.awake.now(io);
    if (staged_bytes != spec.body_len or
        builder.record_reader.completed_body_bytes != @as(u64, @intCast(spec.body_len)))
        return error.IncorrectOutput;
    return .{ .nanoseconds = start.durationTo(end).nanoseconds,
        .records = count, .items = items, .checksum = 0,
        .batches = batches, .copied_spans = builder.record_reader.copied_spans };
}

fn measurePipeline(a: std.mem.Allocator, io: std.Io, spec: Spec, ordered: bool) !Sample {
    return measurePipelineSized(a, io, spec, ordered, 256 * 1024, 16 * 1024 * 1024);
}

fn measurePipelineSized(
    a: std.mem.Allocator,
    io: std.Io,
    spec: Spec,
    ordered: bool,
    chunk_bytes: usize,
    budget_bytes: usize,
) !Sample {
    var reader: std.Io.Reader = .fixed(spec.bytes);
    const start = std.Io.Clock.awake.now(io);
    var parser = try internals.parser.Parser.init(a, io, &reader, .{
        .chunk_size = chunk_bytes,
        .memory_budget = budget_bytes,
        .preserve_order = ordered,
    });
    errdefer parser.deinit();
    var records: usize = 0;
    var items: usize = 0;
    var sum: u64 = 0;
    var batches: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        batches += 1;
        records += batch.info().record_count;
        const lists = try batch.listColumn(0);
        for (0..batch.info().record_count) |row| {
            const vals = lists.row(row).?.i32;
            items += vals.len;
            for (vals) |item| sum += @intCast(item);
        }
    }
    const stats = parser.memoryStats();
    if (stats.peak_total_bytes > stats.budget_bytes or stats.peak_total_bytes > budget_bytes)
        return error.MemoryBudgetExceeded;
    const peak = stats.peak_total_bytes;
    const reductions = stats.batch_reductions;
    const copied_spans = parser.binary_stage.record_reader.copied_spans;
    const accepted = parser.executionStats().native_submissions;
    parser.deinit();
    const end = std.Io.Clock.awake.now(io);
    return .{ .nanoseconds = start.durationTo(end).nanoseconds,
        .records = records, .items = items, .checksum = sum,
        .batches = batches, .peak = peak, .accepted = accepted,
        .copied_spans = copied_spans, .batch_reductions = reductions };
}

fn report(name: []const u8, io: std.Io, a: std.mem.Allocator, spec: Spec, mode: enum { scan, chunk, ordered, unordered }) !void {
    for (0..warmups) |_| {
        const s = switch (mode) {
            .scan => try measureScan(a, io, spec),
            .chunk => try measureChunkAssembly(a, io, spec),
            .ordered, .unordered => try measurePipeline(a, io, spec, mode == .ordered),
        };
        if (s.records != spec.record_count or s.items != spec.item_count or
            (mode != .scan and mode != .chunk and s.checksum != spec.checksum))
            return error.IncorrectOutput;
    }
    var times: [rounds]i96 = undefined;
    var last: Sample = undefined;
    for (&times) |*t| {
        last = switch (mode) {
            .scan => try measureScan(a, io, spec),
            .chunk => try measureChunkAssembly(a, io, spec),
            .ordered, .unordered => try measurePipeline(a, io, spec, mode == .ordered),
        };
        if (last.records != spec.record_count or last.items != spec.item_count or
            (mode != .scan and mode != .chunk and last.checksum != spec.checksum))
            return error.IncorrectOutput;
        t.* = last.nanoseconds;
    }
    std.mem.sortUnstable(i96, &times, {}, std.sort.asc(i96));
    const seconds = @as(f64, @floatFromInt(times[rounds / 2])) / 1e9;
    std.debug.print("  {s}: median={d:.3} ms {d:.2} Mrec/s {d:.2} Mitems/s {d:.3} GB/s batches={d} peak={d} native={d} copied_spans={d} reductions={d}\n", .{
        name, seconds * 1e3, @as(f64, @floatFromInt(spec.record_count)) / seconds / 1e6,
        @as(f64, @floatFromInt(spec.item_count)) / seconds / 1e6,
        @as(f64, @floatFromInt(spec.body_len)) / seconds / 1e9,
        last.batches, last.peak, last.accepted, last.copied_spans, last.batch_reductions,
    });
}

pub fn main(init: std.process.Init) !void {
    var single: std.Io.Threaded = .init_single_threaded;
    var threaded: std.Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    std.debug.print("Phase 10 binary lists: {d} warmups + {d} measured runs; input generation excluded\n", .{ warmups, rounds });
    inline for (.{ Kind.triangles, Kind.mixed_polygons }) |kind| {
        inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
            const spec = try make(init.gpa, kind, endian);
            defer init.gpa.free(spec.bytes);
            std.debug.print("{s} {s}: {d} records {d} items {d} body bytes\n", .{
                @tagName(kind), @tagName(endian), spec.record_count, spec.item_count, spec.body_len,
            });
            try report("structural scan", single.io(), init.gpa, spec, .scan);
            try report("chunk assembly", single.io(), init.gpa, spec, .chunk);
            try report("single ordered", single.io(), init.gpa, spec, .ordered);
            try report("threaded ordered", threaded.io(), init.gpa, spec, .ordered);
            try report("threaded unordered", threaded.io(), init.gpa, spec, .unordered);
        }
    }
}

/// Opt-in bounded-memory configuration matrix. Fixture creation is excluded
/// from timing, and every measured run verifies full decoded item checksums.
/// This is intentionally separate from the quick fixed-configuration bench.
pub fn runMatrix(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const budgets = [_]usize{ 16 * 1024 * 1024, 64 * 1024 * 1024, 256 * 1024 * 1024 };
    const chunks = [_]usize{ 64 * 1024, 256 * 1024, 1024 * 1024 };
    std.debug.print("Phase 10 binary list matrix: 1 warmup + 3 measured runs; input generation excluded; native std.Io executor\n", .{});
    inline for (.{ Kind.triangles, Kind.mixed_polygons }) |kind| {
        inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
            const spec = try make(init.gpa, kind, endian);
            defer init.gpa.free(spec.bytes);
            std.debug.print("{s} {s}: {d} records {d} items {d} input bytes\n", .{
                @tagName(kind), @tagName(endian), spec.record_count, spec.item_count, spec.body_len,
            });
            for (budgets) |budget| {
                for (chunks) |chunk| {
                    inline for (.{ true, false }) |ordered| {
                        const io = threaded.io();
                        const warm = try measurePipelineSized(init.gpa, io, spec, ordered, chunk, budget);
                        try checkMatrixResult(warm, spec, budget);
                        var times: [3]i96 = undefined;
                        var last: Sample = undefined;
                        for (&times) |*time| {
                            last = try measurePipelineSized(init.gpa, io, spec, ordered, chunk, budget);
                            try checkMatrixResult(last, spec, budget);
                            time.* = last.nanoseconds;
                        }
                        std.mem.sortUnstable(i96, &times, {}, std.sort.asc(i96));
                        const seconds = @as(f64, @floatFromInt(times[1])) / 1e9;
                        std.debug.print("  budget={d}MiB chunk={d}KiB {s}: median={d:.3}ms {d:.2}Mrec/s {d:.2}Mitems/s peak={d} batches={d} native={d} reductions={d}\n", .{
                            budget / (1024 * 1024), chunk / 1024,
                            if (ordered) @as([]const u8, "ordered") else "unordered",
                            seconds * 1000,
                            @as(f64, @floatFromInt(spec.record_count)) / seconds / 1e6,
                            @as(f64, @floatFromInt(spec.item_count)) / seconds / 1e6,
                            last.peak, last.batches, last.accepted, last.batch_reductions,
                        });
                    }
                }
            }
        }
    }
}

fn checkMatrixResult(sample: Sample, spec: Spec, budget: usize) !void {
    if (sample.records != spec.record_count or sample.items != spec.item_count or
        sample.checksum != spec.checksum or sample.peak > budget)
        return error.IncorrectOutput;
}
