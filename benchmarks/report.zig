//! Phase 12 M2/M3: one versioned CSV schema for all supported encodings.
//! A `sample` row contains one measured run. A `summary` row contains
//! median latency and nearest-rank p05/p95 across the samples.
//! All decoded values are verified before either type of row is emitted.
const std = @import("std");
const configuration = @import("config.zig");
const statistics = @import("statistics.zig");
const m16 = @import("phase11_performance.zig");
const digest_mod = @import("digest.zig");

pub const header = "row_type,workload,mode,consumer,records,body_bytes,list_items,chunk_bytes,budget_bytes,warmups,rounds,round,lifecycle_ns,body_ns,lifecycle_p05_ns,lifecycle_p95_ns,body_p05_ns,body_p95_ns,records_per_s,input_gbps,list_items_per_s,parser_peak_bytes,allocation_count,batches,native_submissions,inline_decodes,max_active,fixture_digest_sum,fixture_digest_xor,consumer_digest_sum,consumer_digest_xor";

/// Fixture metadata shared by the legacy M16 workloads and the extended M3
/// matrix. Keeping it independent of the workload enum lets one report
/// schema serve both suites without changing any CSV column.
pub const Meta = struct {
    workload: []const u8,
    records: usize,
    body_bytes: usize,
    list_items: usize,
    digest: digest_mod.Digest,
};

/// Timing and accounting fields common to every suite's sample type.
pub const Measurement = struct {
    body_nanoseconds: i96,
    nanoseconds: i96,
    batches: usize,
    peak_bytes: usize,
    allocation_count: u64,
    native_submissions: u64,
    inline_decodes: u64,
    max_active: usize,
    consumer_digest: digest_mod.Digest,
};

pub const Row = struct {
    row_type: []const u8,
    meta: Meta,
    mode: m16.Mode,
    config: configuration.Config,
    round: i64,
    lifecycle_ns: i96,
    body_ns: i96,
    lifecycle_p05_ns: i96,
    lifecycle_p95_ns: i96,
    body_p05_ns: i96,
    body_p95_ns: i96,
    parser_peak_bytes: usize,
    allocation_count: u64,
    batches: usize,
    native_submissions: u64,
    inline_decodes: u64,
    max_active: usize,
    consumer_digest: digest_mod.Digest,
};

pub fn printHeader() void {
    std.debug.print("{s}\n", .{header});
}

pub fn print(row: Row) void {
    const seconds: f64 = @as(f64, @floatFromInt(row.lifecycle_ns)) / 1e9;
    std.debug.print(
        "{s},{s},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.1},{d:.6},{d:.1},{d},{d},{d},{d},{d},{d},{x},{x},{x},{x}\n",
        .{
            row.row_type,
            row.meta.workload,
            row.mode.label(),
            row.config.consumer.label(),
            row.meta.records,
            row.meta.body_bytes,
            row.meta.list_items,
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
            @as(f64, @floatFromInt(row.meta.records)) / seconds,
            @as(f64, @floatFromInt(row.meta.body_bytes)) / seconds / 1e9,
            @as(f64, @floatFromInt(row.meta.list_items)) / seconds,
            row.parser_peak_bytes,
            row.allocation_count,
            row.batches,
            row.native_submissions,
            row.inline_decodes,
            row.max_active,
            row.meta.digest.sum,
            row.meta.digest.xor_value,
            row.consumer_digest.sum,
            row.consumer_digest.xor_value,
        },
    );
}

pub fn sample(config: configuration.Config, meta: Meta, mode: m16.Mode, round: usize, result: Measurement) void {
    print(.{
        .row_type = "sample",
        .meta = meta,
        .mode = mode,
        .config = config,
        .round = @intCast(round),
        .lifecycle_ns = result.nanoseconds,
        .body_ns = result.body_nanoseconds,
        .lifecycle_p05_ns = result.nanoseconds,
        .lifecycle_p95_ns = result.nanoseconds,
        .body_p05_ns = result.body_nanoseconds,
        .body_p95_ns = result.body_nanoseconds,
        .parser_peak_bytes = result.peak_bytes,
        .allocation_count = result.allocation_count,
        .batches = result.batches,
        .native_submissions = result.native_submissions,
        .inline_decodes = result.inline_decodes,
        .max_active = result.max_active,
        .consumer_digest = result.consumer_digest,
    });
}

pub fn summary(config: configuration.Config, meta: Meta, mode: m16.Mode, life: statistics.Summary, body: statistics.Summary, peak: usize, last: Measurement) void {
    print(.{
        .row_type = "summary",
        .meta = meta,
        .mode = mode,
        .config = config,
        .round = -1,
        .lifecycle_ns = life.median,
        .body_ns = body.median,
        .lifecycle_p05_ns = life.p05,
        .lifecycle_p95_ns = life.p95,
        .body_p05_ns = body.p05,
        .body_p95_ns = body.p95,
        .parser_peak_bytes = peak,
        .allocation_count = last.allocation_count,
        .batches = last.batches,
        .native_submissions = last.native_submissions,
        .inline_decodes = last.inline_decodes,
        .max_active = last.max_active,
        .consumer_digest = last.consumer_digest,
    });
}
