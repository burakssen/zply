//! Phase 8 numeric conversion and tokenizer microbenchmark (pure primitives).
const std = @import("std");
const internal = @import("zply_internals");

const repeats: usize = 1_000_000;

pub fn main(init: std.process.Init) !void {
    var single: std.Io.Threaded = .init_single_threaded;
    const io = single.io();
    const start = std.Io.Clock.awake.now(io);
    // Use mutable, escaped token tables so ReleaseFast cannot replace
    // the entire integer loop with a single constant checksum.
    var integer_tokens = [_][]const u8{ "12345", "12346", "-123", "-124" };
    std.mem.doNotOptimizeAway(&integer_tokens);
    var isum: i64 = 0;
    for (0..repeats) |i| {
        const variant = i & 1;
        isum += try internal.ascii.number.parse(i32, integer_tokens[variant]);
        isum += try internal.ascii.number.parse(i16, integer_tokens[2 + variant]);
    }
    std.mem.doNotOptimizeAway(isum);
    const int_end = std.Io.Clock.awake.now(io);
    var float_tokens = [_][]const u8{ "1.2345e-8", "2.2345e-8", "-2.5e-4", "-3.5e-4" };
    std.mem.doNotOptimizeAway(&float_tokens);
    var fsum: f64 = 0;
    for (0..repeats) |i| {
        const variant = i & 1;
        fsum += try internal.ascii.number.parse(f64, float_tokens[variant]);
        fsum += @as(f64, try internal.ascii.number.parse(f32, float_tokens[2 + variant]));
    }
    std.mem.doNotOptimizeAway(fsum);
    const float_end = std.Io.Clock.awake.now(io);
    var token_inputs = [_][]const u8{
        "  12345\t-123   1.2345e-8 -2.5e-4",
        "  12346\t-124   2.2345e-8 -3.5e-4",
    };
    std.mem.doNotOptimizeAway(&token_inputs);
    var tokens: usize = 0;
    for (0..repeats) |i| {
        var t = internal.ascii.Tokenizer.init(token_inputs[i & 1], 64);
        while (try t.next()) |_| tokens += 1;
    }
    std.mem.doNotOptimizeAway(tokens);
    const end = std.Io.Clock.awake.now(io);
    const ins = start.durationTo(int_end).nanoseconds;
    const fns = int_end.durationTo(float_end).nanoseconds;
    const tns = float_end.durationTo(end).nanoseconds;
    // A zero measured interval indicates optimized-away work or inadequate
    // timer resolution; never report an infinite throughput.
    if (ins == 0 or fns == 0 or tns == 0) return error.InvalidBenchmarkInterval;
    std.debug.print("Phase 8 numeric conversion benchmark: {d} iterations, checksum={d}:{d:.6}:{d}\n" ++
        "  integers: {d:.2} Mvalues/s\n  floating: {d:.2} Mvalues/s\n  tokenizer: {d:.2} Mtokens/s\n", .{
        repeats,                                                                               isum,                                                                                  fsum,                                                                         tokens,
        (2.0 * @as(f64, @floatFromInt(repeats))) / (@as(f64, @floatFromInt(ins)) / 1e9) / 1e6, (2.0 * @as(f64, @floatFromInt(repeats))) / (@as(f64, @floatFromInt(fns)) / 1e9) / 1e6, @as(f64, @floatFromInt(tokens)) / (@as(f64, @floatFromInt(tns)) / 1e9) / 1e6,
    });
    _ = init;
}
