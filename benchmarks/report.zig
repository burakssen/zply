//! Phase 12 M2: one versioned CSV schema for all supported encodings.
//! A `sample` row contains one measured run. A `summary` row contains
//! median latency and nearest-rank p05/p95 across the samples.
//! All decoded values are verified before either type of row is emitted.
const std = @import("std");
const m16 = @import("phase11_performance.zig");
const configuration = @import("config.zig");
const statistics = @import("statistics.zig");

pub const header = "row_type,workload,mode,records,body_bytes,list_items,chunk_bytes,budget_bytes,warmups,rounds,round,lifecycle_ns,body_ns,lifecycle_p05_ns,lifecycle_p95_ns,body_p05_ns,body_p95_ns,records_per_s,input_gbps,list_items_per_s,parser_peak_bytes,batches,native_submissions,inline_decodes,max_active,digest_sum,digest_xor";

pub const Row = struct {
    row_type: []const u8,
    kind: m16.Kind,
    mode: m16.Mode,
    input: m16.Input,
    config: configuration.Config,
    round: i64,
    lifecycle_ns: i96,
    body_ns: i96,
    lifecycle_p05_ns: i96,
    lifecycle_p95_ns: i96,
    body_p05_ns: i96,
    body_p95_ns: i96,
    parser_peak_bytes: usize,
    batches: usize,
    native_submissions: u64,
    inline_decodes: u64,
    max_active: usize,
};

pub fn printHeader() void {
    std.debug.print("{s}\n", .{header});
}

pub fn print(row: Row) void {
    const seconds: f64 = @as(f64, @floatFromInt(row.lifecycle_ns)) / 1e9;
    std.debug.print(
        "{s},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.1},{d:.6},{d:.1},{d},{d},{d},{d},{d},{x},{x}\n",
        .{
            row.row_type,
            @tagName(row.kind),
            row.mode.label(),
            row.input.records,
            row.input.body_bytes,
            row.input.list_items,
            row.config.chunkFor(row.mode),
            row.config.budget_bytes,
            row.config.warmups,
            row.config.rounds,
            row.round,
            row.lifecycle_ns,
            row.body_ns,
            row.lifecycle_p05_ns,
            row.lifecycle_p95_ns,
            row.body_p05_ns,
            row.body_p95_ns,
            @as(f64, @floatFromInt(row.input.records)) / seconds,
            @as(f64, @floatFromInt(row.input.body_bytes)) / seconds / 1e9,
            @as(f64, @floatFromInt(row.input.list_items)) / seconds,
            row.parser_peak_bytes,
            row.batches,
            row.native_submissions,
            row.inline_decodes,
            row.max_active,
            row.input.expected.sum,
            row.input.expected.xor_value,
        },
    );
}

pub fn sample(config: configuration.Config, input: m16.Input, mode: m16.Mode, round: usize, result: m16.Sample) void {
    print(.{
        .row_type = "sample",
        .kind = input.kind,
        .mode = mode,
        .input = input,
        .config = config,
        .round = @intCast(round),
        .lifecycle_ns = result.nanoseconds,
        .body_ns = result.body_nanoseconds,
        .lifecycle_p05_ns = result.nanoseconds,
        .lifecycle_p95_ns = result.nanoseconds,
        .body_p05_ns = result.body_nanoseconds,
        .body_p95_ns = result.body_nanoseconds,
        .parser_peak_bytes = result.peak_bytes,
        .batches = result.batches,
        .native_submissions = result.native_submissions,
        .inline_decodes = result.inline_decodes,
        .max_active = result.max_active,
    });
}

pub fn summary(config: configuration.Config, input: m16.Input, mode: m16.Mode, life: statistics.Summary, body: statistics.Summary, peak: usize, last: m16.Sample) void {
    print(.{
        .row_type = "summary",
        .kind = input.kind,
        .mode = mode,
        .input = input,
        .config = config,
        .round = -1,
        .lifecycle_ns = life.median,
        .body_ns = body.median,
        .lifecycle_p05_ns = life.p05,
        .lifecycle_p95_ns = life.p95,
        .body_p05_ns = body.p05,
        .body_p95_ns = body.p95,
        .parser_peak_bytes = peak,
        .batches = last.batches,
        .native_submissions = last.native_submissions,
        .inline_decodes = last.inline_decodes,
        .max_active = last.max_active,
    });
}
