//! Phase 12 M2 unified, parameterized, warm-memory end-to-end PLY benchmark.
//! CSV is written to stderr, like the prior Phase 11 M16 capture. Examples:
//!   zig build bench-phase12 -Doptimize=ReleaseFast 2> phase12.csv
//!   zig build bench-phase12 -Doptimize=ReleaseFast -- --records=10000 --rounds=3
const std = @import("std");
const config_mod = @import("config.zig");
const harness = @import("harness.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try config_mod.parse(args);
    if (config.help) {
        config_mod.usage();
        return;
    }

    var single: std.Io.Threaded = .init_single_threaded;
    var threaded: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .limited(4) });
    defer threaded.deinit();
    try harness.run(init.gpa, &single, &threaded, config);
}
