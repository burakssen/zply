//! Phase 12 M2: CLI configuration for the shared end-to-end harness.
//! All flags are local to the benchmark executable, never Parser.Options.
const std = @import("std");
const m16 = @import("phase11_performance.zig");

pub const Config = struct {
    records: usize = m16.record_count,
    chunk_bytes: usize = m16.normal_chunk,
    small_chunk_bytes: usize = m16.small_chunk,
    budget_bytes: usize = m16.memory_budget,
    warmups: usize = 3,
    rounds: usize = 15,
    workload: ?m16.Kind = null,
    mode: ?m16.Mode = null,
    help: bool = false,

    pub fn chunkFor(self: Config, mode: m16.Mode) usize {
        return if (mode == .single_small_chunk) self.small_chunk_bytes else self.chunk_bytes;
    }

    pub fn selectedWorkload(self: Config, kind: m16.Kind) bool {
        return self.workload == null or self.workload.? == kind;
    }

    pub fn selectedMode(self: Config, mode: m16.Mode) bool {
        return self.mode == null or self.mode.? == mode;
    }
};

fn parseKind(value: []const u8) !m16.Kind {
    inline for (m16.workloads) |kind| {
        if (std.mem.eql(u8, value, @tagName(kind))) return kind;
    }
    return error.UnknownWorkload;
}

fn parseMode(value: []const u8) !m16.Mode {
    inline for (m16.modes) |mode| {
        if (std.mem.eql(u8, value, mode.label())) return mode;
    }
    return error.UnknownMode;
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
            config.workload = try parseKind(argument[11..]);
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
        "Phase 12 M2 unified PLY benchmark (CSV written to stderr)\n" ++
            "  zig build bench-phase12 -Doptimize=ReleaseFast -- [options]\n" ++
            "  --workload=<name>          one of seven M16 workloads (default all)\n" ++
            "  --mode=<name>              single-ordered, threaded-ordered, threaded-unordered, single-small-chunk\n" ++
            "  --records=<N>              records per dataset (default 250000)\n" ++
            "  --chunk-bytes=<N>          ordinary chunk target (default 262144)\n" ++
            "  --small-chunk-bytes=<N>    small chunk target (default 8192)\n" ++
            "  --budget-bytes=<N>         parser budget (default 16777216)\n" ++
            "  --warmups=<N>              default 3\n" ++
            "  --rounds=<N>               default 15\n" ++
            "  --help\n",
        .{},
    );
}
