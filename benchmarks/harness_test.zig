//! Phase 12 M2: deterministic, fast tests for statistics, CLI and digest.
const std = @import("std");
const config_mod = @import("config.zig");
const statistics = @import("statistics.zig");
const digest = @import("digest.zig");
const m16 = @import("phase11_performance.zig");

test "M2 percentiles are nearest rank and median is middle order statistic" {
    const values = [_]i96{ 80, 40, 20, 100, 60 };
    const summary = try statistics.summarize(std.testing.allocator, &values);
    try std.testing.expectEqual(@as(i96, 60), summary.median);
    try std.testing.expectEqual(@as(i96, 20), summary.p05);
    try std.testing.expectEqual(@as(i96, 100), summary.p95);
}

test "M2 empty and nonpositive measurements are rejected" {
    try std.testing.expectError(error.NoSamples, statistics.summarize(std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidMeasurement, statistics.summarize(std.testing.allocator, &[_]i96{ 1, 0, 3 }));
}

test "M2 record digest is insensitive to batch delivery order" {
    var a: digest.Digest = .{};
    var b: digest.Digest = .{};
    a.add(1);
    a.add(2);
    a.add(3);
    b.add(3);
    b.add(1);
    b.add(2);
    try std.testing.expect(a.eql(b));
    b.add(4);
    try std.testing.expect(!a.eql(b));
}

test "M2 CLI parses explicit benchmark selection and memory parameters" {
    const args = [_][]const u8{
        "bench",               "--workload=binary_polygons_be", "--mode=threaded-ordered", "--records=128",
        "--chunk-bytes=65536", "--small-chunk-bytes=8192",      "--budget-bytes=1048576",  "--warmups=0",
        "--rounds=3",
    };
    const config = try config_mod.parse(&args);
    try std.testing.expect(config.selectedWorkload(.binary_polygons_be));
    try std.testing.expect(!config.selectedWorkload(.ascii_xyz));
    try std.testing.expect(config.selectedMode(.threaded_ordered));
    try std.testing.expect(!config.selectedMode(.single_ordered));
    try std.testing.expectEqual(@as(usize, 128), config.records);
    try std.testing.expectEqual(@as(usize, 3), config.rounds);
    try std.testing.expectEqual(@as(usize, 8192), config.chunkFor(.single_small_chunk));
    try std.testing.expectEqual(@as(usize, 65536), config.chunkFor(.threaded_ordered));
}

test "M2 invalid CLI options are rejected" {
    try std.testing.expectError(error.UnknownBenchmarkOption, config_mod.parse(&.{ "bench", "--unknown" }));
    try std.testing.expectError(error.UnknownWorkload, config_mod.parse(&.{ "bench", "--workload=xyz" }));
    try std.testing.expectError(error.UnknownMode, config_mod.parse(&.{ "bench", "--mode=fast" }));
    try std.testing.expectError(error.InvalidBenchmarkOption, config_mod.parse(&.{ "bench", "--rounds=0" }));
    try std.testing.expectError(error.InvalidBenchmarkOption, config_mod.parse(&.{ "bench", "--chunk-bytes=999999999" }));
}

test "M2 small end-to-end samples verify all three encodings and dual timing scopes" {
    var single: std.Io.Threaded = .init_single_threaded;
    inline for (.{ m16.Kind.binary_xyz_f32, m16.Kind.binary_polygons_be, m16.Kind.ascii_xyz, m16.Kind.ascii_polygons }) |kind| {
        const input = try m16.createInputWithRecords(std.testing.allocator, kind, 128);
        defer input.deinit(std.testing.allocator);
        const result = try m16.runOnceConfigured(std.testing.allocator, single.io(), input, .single_ordered, .{
            .chunk_size = 4096,
            .memory_budget = 1024 * 1024,
        });
        try std.testing.expect(result.nanoseconds >= result.body_nanoseconds);
        try std.testing.expect(result.body_nanoseconds > 0);
        try std.testing.expect(result.peak_bytes <= 1024 * 1024);
        try std.testing.expect(result.batches > 0);
    }
}
