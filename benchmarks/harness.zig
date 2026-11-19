//! Phase 12 M2/M3: shared cross-encoding measurement protocol.
//! Fixture generation, trial arrays and summaries are outside the timers.
//! The existing M16 validated consumer is reused without reimplementing PLY,
//! and the extended M3 matrix adds wide, mixed and multi-element fixtures.
const std = @import("std");
const config_mod = @import("config.zig");
const m16 = @import("phase11_performance.zig");
const p12 = @import("phase12_workloads.zig");
const report = @import("report.zig");
const statistics = @import("statistics.zig");

fn measurement(result: anytype) report.Measurement {
    return .{
        .body_nanoseconds = result.body_nanoseconds,
        .nanoseconds = result.nanoseconds,
        .batches = result.batches,
        .peak_bytes = result.peak_bytes,
        .allocation_count = result.allocation_count,
        .native_submissions = result.native_submissions,
        .inline_decodes = result.inline_decodes,
        .max_active = result.max_active,
        .consumer_digest = result.consumer_digest,
    };
}

const LegacyCase = struct {
    kind: m16.Kind,
    input: m16.Input,

    fn meta(self: LegacyCase) report.Meta {
        return .{
            .workload = @tagName(self.kind),
            .records = self.input.records,
            .body_bytes = self.input.body_bytes,
            .list_items = self.input.list_items,
            .digest = self.input.expected,
        };
    }

    fn run(self: LegacyCase, allocator: std.mem.Allocator, io: std.Io, mode: m16.Mode, options: m16.RunOptions) !m16.Sample {
        return m16.runOnceConfigured(allocator, io, self.input, mode, options);
    }
};

const ExtendedCase = struct {
    kind: p12.Kind,
    input: p12.Input,

    fn meta(self: ExtendedCase) report.Meta {
        return .{
            .workload = @tagName(self.kind),
            .records = self.input.records,
            .body_bytes = self.input.body_bytes,
            .list_items = self.input.list_items,
            .digest = self.input.expected,
        };
    }

    fn run(self: ExtendedCase, allocator: std.mem.Allocator, io: std.Io, mode: m16.Mode, options: p12.RunOptions) !p12.Sample {
        return p12.runOnceConfigured(allocator, io, self.input, mode, options);
    }
};

fn measure(
    allocator: std.mem.Allocator,
    single: *std.Io.Threaded,
    threaded: *std.Io.Threaded,
    config: config_mod.Config,
    case: anytype,
) !void {
    var selected: [m16.modes.len]m16.Mode = undefined;
    var count: usize = 0;
    for (m16.modes) |mode| {
        if (!config.selectedMode(mode)) continue;
        selected[count] = mode;
        count += 1;
    }
    std.debug.assert(count > 0);

    // Use the common Measurement type for all slots.
    var slots: [m16.modes.len][]report.Measurement = undefined;
    for (0..m16.modes.len) |index| slots[index] = &.{};
    defer {
        for (slots) |slot| {
            if (slot.len > 0) allocator.free(slot);
        }
    }
    for (selected[0..count]) |mode| {
        slots[@backingInt(mode)] = try allocator.alloc(report.Measurement, config.rounds);
    }

    for (0..config.warmups + config.rounds) |trial| {
        for (0..count) |slot| {
            const mode = selected[(trial + slot) % count];
            const io = if (mode == .threaded_ordered or mode == .threaded_unordered) threaded.io() else single.io();
            const result = try case.run(allocator, io, mode, .{
                .chunk_size = config.chunkFor(mode),
                .memory_budget = config.budget_bytes,
                .consumer = config.consumer,
            });
            if (trial >= config.warmups) {
                const round = trial - config.warmups;
                slots[@backingInt(mode)][round] = measurement(result);
                report.sample(config, case.meta(), mode, round, measurement(result));
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
        report.summary(config, case.meta(), mode, life_summary, body_summary, peak, samples[samples.len - 1]);
    }
}

pub fn run(allocator: std.mem.Allocator, single: *std.Io.Threaded, threaded: *std.Io.Threaded, config: config_mod.Config) !void {
    report.printHeader();
    for (m16.workloads) |kind| {
        if (!config.selectedLegacy(kind)) continue;
        const input = try m16.createInputWithRecords(allocator, kind, config.records);
        defer input.deinit(allocator);
        try measure(allocator, single, threaded, config, LegacyCase{ .kind = kind, .input = input });
    }
    for (p12.workloads) |kind| {
        if (!config.selectedExtended(kind)) continue;
        const input = try p12.createInputWithRecords(allocator, kind, config.records);
        defer input.deinit(allocator);
        try measure(allocator, single, threaded, config, ExtendedCase{ .kind = kind, .input = input });
    }
}
