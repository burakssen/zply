//! Phase 12 M2/M3: CLI configuration for the shared end-to-end harness.
//! All flags are local to the benchmark executable, never Parser.Options.
const std = @import("std");
const m16 = @import("phase11_performance.zig");
const p12 = @import("phase12_workloads.zig");

/// A workload name may select either the preserved Phase 11 suite or the
/// extended Phase 12 matrix. The two enums stay separate so the legacy
/// `bench-phase11` CSV contract cannot drift.
pub const Selection = union(enum) {
    legacy: m16.Kind,
    extended: p12.Kind,
};

pub const Config = struct {
    records: usize = m16.record_count,
    chunk_bytes: usize = m16.normal_chunk,
    small_chunk_bytes: usize = m16.small_chunk,
    budget_bytes: usize = m16.memory_budget,
    warmups: usize = 3,
    rounds: usize = 15,
    consumer: m16.Consumer = .validation,
    workload: ?Selection = null,
    mode: ?m16.Mode = null,
    help: bool = false,

    pub fn chunkFor(self: Config, mode: m16.Mode) usize {
        return if (mode == .single_small_chunk) self.small_chunk_bytes else self.chunk_bytes;
    }

    pub fn selectedLegacy(self: Config, kind: m16.Kind) bool {
        const selection = self.workload orelse return true;
        return switch (selection) {
            .legacy => |selected| selected == kind,
            .extended => false,
        };
    }

    pub fn selectedExtended(self: Config, kind: p12.Kind) bool {
        const selection = self.workload orelse return true;
        return switch (selection) {
            .extended => |selected| selected == kind,
            .legacy => false,
        };
    }

    pub fn selectedMode(self: Config, mode: m16.Mode) bool {
        return self.mode == null or self.mode.? == mode;
    }
};

fn parseWorkload(value: []const u8) !Selection {
    inline for (m16.workloads) |kind| {
        if (std.mem.eql(u8, value, @tagName(kind))) return .{ .legacy = kind };
    }
    inline for (p12.workloads) |kind| {
        if (std.mem.eql(u8, value, @tagName(kind))) return .{ .extended = kind };
    }
    return error.UnknownWorkload;
}

fn parseMode(value: []const u8) !m16.Mode {
    inline for (m16.modes) |mode| {
        if (std.mem.eql(u8, value, mode.label())) return mode;
    }
    return error.UnknownMode;
}

fn parseConsumer(value: []const u8) !m16.Consumer {
    inline for (std.enums.values(m16.Consumer)) |consumer| {
        if (std.mem.eql(u8, value, consumer.label())) return consumer;
    }
    return error.UnknownConsumer;
}

fn unsigned(value: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch error.InvalidBenchmarkOption;
}

pub fn parse(args: []const []const u8) !Config {
    var config: Config = .{};
    // argv[0] names the program, all other args must be named options.
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--help")) {
            config.help = true;
        } else if (std.mem.startsWith(u8, argument, "--workload=")) {
            config.workload = try parseWorkload(argument[11..]);
        } else if (std.mem.startsWith(u8, argument, "--mode=")) {
            config.mode = try parseMode(argument[7..]);
        } else if (std.mem.startsWith(u8, argument, "--records=")) {
            config.records = try unsigned(argument[10..]);
        } else if (std.mem.startsWith(u8, argument, "--chunk-bytes=")) {
            config.chunk_bytes = try unsigned(argument[14..]);
        } else if (std.mem.startsWith(u8, argument, "--small-chunk-bytes=")) {
            config.small_chunk_bytes = try unsigned(argument[20..]);
        } else if (std.mem.startsWith(u8, argument, "--budget-bytes=")) {
            config.budget_bytes = try unsigned(argument[15..]);
        } else if (std.mem.startsWith(u8, argument, "--warmups=")) {
            config.warmups = try unsigned(argument[10..]);
        } else if (std.mem.startsWith(u8, argument, "--rounds=")) {
            config.rounds = try unsigned(argument[9..]);
        } else if (std.mem.startsWith(u8, argument, "--consumer=")) {
            config.consumer = try parseConsumer(argument[11..]);
        } else {
            return error.UnknownBenchmarkOption;
        }
    }
    if (config.help) return config;
    if (config.records == 0 or config.records > 100_000_000 or
        config.chunk_bytes == 0 or config.small_chunk_bytes == 0 or
        config.budget_bytes < 4096 or config.rounds == 0 or config.rounds > 1000 or
        config.warmups > 1000 or config.chunk_bytes > config.budget_bytes or
        config.small_chunk_bytes > config.budget_bytes or
        config.warmups > std.math.maxInt(usize) - config.rounds)
    {
        return error.InvalidBenchmarkOption;
    }
    return config;
}

pub fn usage() void {
    std.debug.print(
        "Phase 12 unified PLY benchmark (CSV written to stderr)\n" ++
            "  zig build bench-phase12 -Doptimize=ReleaseFast -- [options]\n" ++
            "  --workload=<name>          Phase 11 or Phase 12 workload (default all)\n" ++
            "  --mode=<name>              single-ordered, threaded-ordered, threaded-unordered, single-small-chunk\n" ++
            "  --records=<N>              records per dataset (default 250000; per element for multi-element files)\n" ++
            "  --chunk-bytes=<N>          ordinary chunk target (default 262144)\n" ++
            "  --small-chunk-bytes=<N>    small chunk target (default 8192)\n" ++
            "  --budget-bytes=<N>         parser budget (default 16777216)\n" ++
            "  --warmups=<N>              default 3\n" ++
            "  --rounds=<N>               default 15\n" ++
            "  --consumer=<name>          validation (default) or minimal\n" ++
            "  --help\n" ++
            "\nPhase 11 workloads: binary_xyz_f32, binary_xyz_f64, binary_xyzrgb,\n" ++
            "  binary_polygons_le, binary_polygons_be, ascii_xyz, ascii_polygons\n" ++
            "Phase 12 workloads: binary_normals, binary_wide, binary_mixed_elements,\n" ++
            "  binary_large_lists, binary_multi_list, ascii_ints, ascii_scientific,\n" ++
            "  ascii_long, ascii_wide\n",
        .{},
    );
}
