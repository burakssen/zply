//! Phase 12 M2: shared cross-encoding measurement protocol.
//! Fixture generation, trial arrays and summaries are outside the timers.
//! The existing M16 validated consumer is reused without reimplementing PLY.
const std = @import("std");
const config_mod = @import("config.zig");
const m16 = @import("phase11_performance.zig");
const report = @import("report.zig");
const statistics = @import("statistics.zig");

pub fn run(allocator: std.mem.Allocator, single: *std.Io.Threaded, threaded: *std.Io.Threaded, config: config_mod.Config) !void {
    report.printHeader();
    for (m16.workloads) |kind| {
        if (!config.selectedWorkload(kind)) continue;
        const input = try m16.createInputWithRecords(allocator, kind, config.records);
        defer input.deinit(allocator);

        var selected: [m16.modes.len]m16.Mode = undefined;
        var count: usize = 0;
        for (m16.modes) |mode| {
            if (!config.selectedMode(mode)) continue;
            selected[count] = mode;
            count += 1;
        }
        std.debug.assert(count > 0);

        var slots: [m16.modes.len][]m16.Sample = undefined;
        for (0..m16.modes.len) |index| slots[index] = &.{};
        defer {
            for (slots) |slot| {
                if (slot.len > 0) allocator.free(slot);
            }
        }
        for (selected[0..count]) |mode| {
            slots[@backingInt(mode)] = try allocator.alloc(m16.Sample, config.rounds);
        }

        for (0..config.warmups + config.rounds) |trial| {
            for (0..count) |slot| {
                const mode = selected[(trial + slot) % count];
                const io = if (mode == .threaded_ordered or mode == .threaded_unordered) threaded.io() else single.io();
                const result = try m16.runOnceConfigured(allocator, io, input, mode, .{
                    .chunk_size = config.chunkFor(mode),
                    .memory_budget = config.budget_bytes,
                });
                if (trial >= config.warmups) {
                    const round = trial - config.warmups;
                    slots[@backingInt(mode)][round] = result;
                    report.sample(config, input, mode, round, result);
                }
            }
        }

        const life = try allocator.alloc(i96, config.rounds);
        defer allocator.free(life);
        const body = try allocator.alloc(i96, config.rounds);
        defer allocator.free(body);
        for (selected[0..count]) |mode| {
            const samples = slots[@backingInt(mode)];
            var peak: usize = 0;
            for (samples, 0..) |result, index| {
                life[index] = result.nanoseconds;
                body[index] = result.body_nanoseconds;
                peak = @max(peak, result.peak_bytes);
            }
            const life_summary = try statistics.summarize(allocator, life);
            const body_summary = try statistics.summarize(allocator, body);
            report.summary(config, input, mode, life_summary, body_summary, peak, samples[samples.len - 1]);
        }
    }
}
