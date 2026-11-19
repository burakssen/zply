//! In-memory binary-decode benchmarks (Task 3.16).
//!
//! Phase 3 has no streaming producer yet, so these benchmarks measure the
//! pure decoder over a fully in-memory buffer: no file I/O, no reader
//! advances, no allocation in the decode path (the decode core has no
//! allocator parameter at all — allocation-freeness is structural, not
//! measured).
//!
//! Methodology:
//!
//! * Every configuration builds one compiled `ElementLayout` by hand
//!   (schema compilation is internal in Phase 2; the decoder consumes
//!   layouts directly, which is exactly how Phase 4 will hand them over).
//! * A deterministic, pseudo-random record buffer is generated once per
//!   configuration; each timed run decodes the whole range and folds all
//!   decoded bits into a checksum, so the compiler cannot eliminate the
//!   decoding work. The checksum is `u64` XOR — cheap relative to
//!   decoding, and NaN-safe (no numeric float arithmetic).
//! * Timing uses the monotonic `Clock.awake` through the process `Io`;
//!   each configuration runs several iterations and the best is
//!   reported, damping scheduler noise.
//! * Reported metrics: bytes/s, records/s, and ns/record.
//!
//! Run with:
//!
//!     zig build bench -Doptimize=ReleaseFast
//!
//! Caveat (per spec): with many simple fixed-width scalars the decoder
//! can become memory-bandwidth-limited; scalar microbenchmarks do not
//! predict full-pipeline throughput.

const std = @import("std");
const ply = @import("zply");

/// Total bytes each configuration decodes per timed run (~8 MiB: large
/// enough to amortize clock resolution, small enough to stay in cache-
/// friendly territory for the smaller record layouts).
const target_bytes: usize = 8 * 1024 * 1024;

const iterations: usize = 5;

const Mode = enum {
    /// Full-range traversal with generic `ScalarValue` decoding.
    range_generic,
    /// Single-scalar hot path with compile-time-known type and offset.
    scalar_concrete_f32,
    /// Same hot path for the 64-bit float.
    scalar_concrete_f64,
    /// Wide-schema traversal that decodes only selected properties.
    projected,
};

const Config = struct {
    name: []const u8,
    layout: ply.ElementLayout,
    endian: std.builtin.Endian,
    mode: Mode,

    /// The compiled+validated wrapper and derived sizes, filled in `main`.
    fixed: ply.decode.FixedLayout = undefined,
    record_count: usize = 0,
    bytes: []u8 = &.{},
    checksum: u64 = 0,
};

fn scalarProperty(
    comptime index: usize,
    comptime offset: usize,
    comptime scalar_type: ply.ScalarType,
) ply.PropertyLayout {
    return .{
        .property_index = index,
        .fixed_offset = offset,
        .fixed_width = scalar_type.byteWidth(),
        .scalar_type = scalar_type,
    };
}

fn elementLayout(
    comptime properties: []const ply.PropertyLayout,
) ply.ElementLayout {
    comptime var total: usize = 0;
    inline for (properties) |property| total += property.fixed_width.?;
    return .{
        .element_index = 0,
        .fixed_record_size = total,
        .minimum_record_size = total,
        .body_start_offset = null,
        .fixed_body_size = null,
        .properties = properties,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const endian_pairs = .{
        .{ std.builtin.Endian.little, "LE" },
        .{ std.builtin.Endian.big, "BE" },
    };

    var configs: [28]Config = undefined;
    var config_count: usize = 0;

    // --- Configuration table -------------------------------------------------
    // Scalar primitives (generic dispatch vs. concrete hot path).
    inline for (endian_pairs) |pair| {
        configs[config_count] = .{
            .name = "f32 scalar (generic)",
            .endian = pair[0],
            .mode = .range_generic,
            .layout = elementLayout(
                &.{scalarProperty(0, 0, .f32)},
            ),
        };
        config_count += 1;
        configs[config_count] = .{
            .name = "f32 scalar (concrete)",
            .endian = pair[0],
            .mode = .scalar_concrete_f32,
            .layout = elementLayout(
                &.{scalarProperty(0, 0, .f32)},
            ),
        };
        config_count += 1;
        configs[config_count] = .{
            .name = "f64 scalar (generic)",
            .endian = pair[0],
            .mode = .range_generic,
            .layout = elementLayout(
                &.{scalarProperty(0, 0, .f64)},
            ),
        };
        config_count += 1;
        configs[config_count] = .{
            .name = "f64 scalar (concrete)",
            .endian = pair[0],
            .mode = .scalar_concrete_f64,
            .layout = elementLayout(
                &.{scalarProperty(0, 0, .f64)},
            ),
        };
        config_count += 1;
        configs[config_count] = .{
            .name = "xyz f32",
            .endian = pair[0],
            .mode = .range_generic,
            .layout = elementLayout(&.{
                scalarProperty(0, 0, .f32),
                scalarProperty(1, 4, .f32),
                scalarProperty(2, 8, .f32),
            }),
        };
        config_count += 1;
        configs[config_count] = .{
            .name = "xyz f64",
            .endian = pair[0],
            .mode = .range_generic,
            .layout = elementLayout(&.{
                scalarProperty(0, 0, .f64),
                scalarProperty(1, 8, .f64),
                scalarProperty(2, 16, .f64),
            }),
        };
        config_count += 1;
        configs[config_count] = .{
            .name = "xyzrgb",
            .endian = pair[0],
            .mode = .range_generic,
            .layout = elementLayout(&.{
                scalarProperty(0, 0, .f32),
                scalarProperty(1, 4, .f32),
                scalarProperty(2, 8, .f32),
                scalarProperty(3, 12, .u8),
                scalarProperty(4, 13, .u8),
                scalarProperty(5, 14, .u8),
            }),
        };
        config_count += 1;
    }

    // Mixed-width custom schemas in the 25–50 byte range, little-endian
    // only (endian behavior is already covered above).
    configs[config_count] = .{
        .name = "mixed 25B (3xf64+u8)",
        .endian = .little,
        .mode = .range_generic,
        .layout = elementLayout(&.{
            scalarProperty(0, 0, .f64),
            scalarProperty(1, 8, .f64),
            scalarProperty(2, 16, .f64),
            scalarProperty(3, 24, .u8),
        }),
    };
    config_count += 1;
    configs[config_count] = .{
        .name = "mixed 31B (f64,f64,f32,f32,u8,i32,u16)",
        .endian = .little,
        .mode = .range_generic,
        .layout = elementLayout(&.{
            scalarProperty(0, 0, .f64),
            scalarProperty(1, 8, .f64),
            scalarProperty(2, 16, .f32),
            scalarProperty(3, 20, .f32),
            scalarProperty(4, 24, .u8),
            scalarProperty(5, 25, .i32),
            scalarProperty(6, 29, .u16),
        }),
    };
    config_count += 1;
    configs[config_count] = .{
        .name = "mixed 50B (6xf64+2xu8)",
        .endian = .little,
        .mode = .range_generic,
        .layout = elementLayout(&.{
            scalarProperty(0, 0, .f64),
            scalarProperty(1, 8, .f64),
            scalarProperty(2, 16, .f64),
            scalarProperty(3, 24, .f64),
            scalarProperty(4, 32, .f64),
            scalarProperty(5, 40, .f64),
            scalarProperty(6, 48, .u8),
            scalarProperty(7, 49, .u8),
        }),
    };
    config_count += 1;

    // Projected access: a 25-byte schema, decoding only the three
    // coordinates (skipping 13 bytes of normals/colors per record).
    configs[config_count] = .{
        .name = "projected xyz from 25B",
        .endian = .little,
        .mode = .projected,
        .layout = elementLayout(&.{
            scalarProperty(0, 0, .f32),
            scalarProperty(1, 4, .f32),
            scalarProperty(2, 8, .f32),
            scalarProperty(3, 12, .f32),
            scalarProperty(4, 16, .f32),
            scalarProperty(5, 20, .f32),
            scalarProperty(6, 24, .u8),
        }),
    };
    config_count += 1;

    // Validate all layouts up front and size the input buffers.
    for (configs[0..config_count]) |*config| {
        config.fixed = try ply.decode.FixedLayout.init(&config.layout, config.endian);
        const record_size = config.fixed.record_size;
        config.record_count = target_bytes / record_size;
        config.bytes = try gpa.alloc(u8, config.record_count * record_size);
    }
    defer {
        for (configs[0..config_count]) |*config| gpa.free(config.bytes);
    }

    // Deterministic pseudo-random record content (same LCG the tests
    // use, so fixture and benchmark data stay reproducible).
    var state: u64 = 0x243F6A8885A308D3;
    for (configs[0..config_count]) |*config| {
        for (config.bytes) |*byte| {
            state = state *% 0x9E3779B97F4A7C15 +% 0x6A09E667F3BCC909;
            byte.* = @truncate(state >> 32);
        }
    }

    // --- Timed runs ----------------------------------------------------------
    var report_buf: [256]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(std.Io.File.stdout(), io, &stdout_buf);
    const stdout = &file_writer.interface;

    try stdout.writeAll(
        \\binary_decode — in-memory Phase 3 decode benchmarks
        \\(best of 5 runs; ~8 MiB decoded per run; mode notes: generic =
        \\compiled-layout dispatch, concrete = compile-time scalar type,
        \\projected = selected properties from a wider schema)
        \\
        \\
    );

    for (configs[0..config_count]) |*config| {
        var best_ns: i96 = std.math.maxInt(i96);

        var run: usize = 0;
        while (run < iterations) : (run += 1) {
            config.checksum = 0;
            const start = std.Io.Clock.awake.now(io);
            try dispatch(config);
            const end = std.Io.Clock.awake.now(io);
            const elapsed = start.durationTo(end).nanoseconds;
            if (elapsed < best_ns) best_ns = elapsed;
        }

        const bytes_per_run: u64 = config.record_count * config.fixed.record_size;
        const gb_s = @as(f64, @floatFromInt(bytes_per_run)) /
            (@as(f64, @floatFromInt(best_ns)) / 1e9) / 1e9;
        const mrec_s = @as(f64, @floatFromInt(config.record_count)) /
            (@as(f64, @floatFromInt(best_ns)) / 1e9) / 1e6;
        const ns_rec = @as(f64, @floatFromInt(best_ns)) /
            @as(f64, @floatFromInt(config.record_count));

        const line = std.fmt.bufPrint(
            &report_buf,
            "{s:<32} {s}  {d:>5} records  {d:>4} B/rec  " ++
                "{d:>6.2} GB/s  {d:>7.2} Mrec/s  {d:>5.2} ns/rec\n",
            .{
                config.name,
                if (config.endian == .little) "LE" else "BE",
                config.record_count,
                config.fixed.record_size,
                gb_s,
                mrec_s,
                ns_rec,
            },
        ) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable, // report_buf sized generously
        };
        try stdout.writeAll(line);
    }

    // The checksums prevent dead-code elimination; print one final digest
    // so every decode's result is observable.
    var combined: u64 = 0;
    for (configs[0..config_count]) |*config| combined ^= config.checksum;
    const digest = std.fmt.bufPrint(&report_buf, "combined checksum: {x:0>16}\n", .{combined}) catch
        unreachable;
    try stdout.writeAll(digest);
    try stdout.flush();
}

/// Runs one timed decode for the configuration's mode.
fn dispatch(config: *Config) !void {
    switch (config.mode) {
        .range_generic => {
            const Consumer = struct {
                checksum: *u64,

                fn consume(self: *@This(), _: u64, view: ply.decode.RecordView) anyerror!void {
                    var values: [16]ply.ScalarValue = undefined;
                    try view.decodeAll(values[0..view.propertyCount()]);
                    for (values[0..view.propertyCount()]) |value| {
                        self.checksum.* ^= value.bits();
                    }
                }
            };
            var consumer = Consumer{ .checksum = &config.checksum };
            try ply.decode.decodeRange(
                config.fixed,
                config.bytes,
                config.record_count,
                &consumer,
                Consumer.consume,
            );
        },
        .scalar_concrete_f32 => {
            // The hot-path primitive: compile-time-known type, direct
            // read from each record's known offset. Simulates Phase 5
            // column decoding without generic dispatch.
            const Consumer = struct {
                checksum: *u64,

                fn consume(self: *@This(), _: u64, view: ply.decode.RecordView) anyerror!void {
                    const value = ply.decode.decodeScalarAs(
                        f32,
                        view.fixed.endian,
                        view.bytes[0..4],
                    ) catch |err| switch (err) {
                        error.InsufficientBytes => return error.InsufficientBytes,
                    };
                    self.checksum.* ^= @as(u32, @bitCast(value));
                }
            };
            var consumer = Consumer{ .checksum = &config.checksum };
            try ply.decode.decodeRange(
                config.fixed,
                config.bytes,
                config.record_count,
                &consumer,
                Consumer.consume,
            );
        },
        .scalar_concrete_f64 => {
            const Consumer = struct {
                checksum: *u64,

                fn consume(self: *@This(), _: u64, view: ply.decode.RecordView) anyerror!void {
                    const value = ply.decode.decodeScalarAs(
                        f64,
                        view.fixed.endian,
                        view.bytes[0..8],
                    ) catch |err| switch (err) {
                        error.InsufficientBytes => return error.InsufficientBytes,
                    };
                    self.checksum.* ^= @as(u64, @bitCast(value));
                }
            };
            var consumer = Consumer{ .checksum = &config.checksum };
            try ply.decode.decodeRange(
                config.fixed,
                config.bytes,
                config.record_count,
                &consumer,
                Consumer.consume,
            );
        },
        .projected => {
            const Consumer = struct {
                checksum: *u64,

                fn consume(self: *@This(), _: u64, view: ply.decode.RecordView) anyerror!void {
                    // Only the first three properties are decoded; the
                    // rest of the 25-byte record is never touched.
                    var i: usize = 0;
                    while (i < 3) : (i += 1) {
                        const value = try view.get(i);
                        self.checksum.* ^= value.bits();
                    }
                }
            };
            var consumer = Consumer{ .checksum = &config.checksum };
            try ply.decode.decodeRange(
                config.fixed,
                config.bytes,
                config.record_count,
                &consumer,
                Consumer.consume,
            );
        },
    }
}
