//! Phase 12 M2: nearest-rank p05/p95 and middle-order-statistic median.
const std = @import("std");

pub const Summary = struct {
    median: i96,
    p05: i96,
    p95: i96,
};

pub fn percentile(sorted: []const i96, percent: usize) i96 {
    std.debug.assert(sorted.len > 0 and percent >= 1 and percent <= 100);
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[@max(@as(usize, 1), rank) - 1];
}

pub fn summarize(allocator: std.mem.Allocator, samples: []const i96) !Summary {
    if (samples.len == 0) return error.NoSamples;
    const sorted = try allocator.dupe(i96, samples);
    defer allocator.free(sorted);
    std.mem.sortUnstable(i96, sorted, {}, std.sort.asc(i96));
    for (sorted) |ns| {
        if (ns <= 0) return error.InvalidMeasurement;
    }
    return .{
        .median = sorted[sorted.len / 2],
        .p05 = percentile(sorted, 5),
        .p95 = percentile(sorted, 95),
    };
}
