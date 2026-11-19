//! Warm-memory sequential streaming benchmark.
//! Run with `zig build bench-streaming -Doptimize=ReleaseFast`.
const std = @import("std");
const internal = @import("zply_internals");

const count = 3_000_000;
const header = "ply\nformat binary_little_endian 1.0\nelement vertex 3000000\n" ++
    "property float x\nproperty float y\nproperty float z\nend_header\n";

const Context = struct {
    checksum: u64 = 0,
    fn consume(self: *Context, index: u64, view: internal.decode.RecordView) anyerror!void {
        const x = try view.get(0);
        const y = try view.get(1);
        const z = try view.get(2);
        self.checksum = (self.checksum *% 0x100000001b3) ^ x.bits() ^ y.bits() ^ z.bits() ^ index;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const data = try allocator.alloc(u8, header.len + count * 12);
    defer allocator.free(data);
    @memcpy(data[0..header.len], header);
    for (data[header.len..], 0..) |*byte, i| byte.* = @truncate(i *% 37);

    std.debug.print("Warm-memory XYZ f32, 3M records; best of 3; GB/s decimal\n", .{});
    for ([_]usize{ 64 * 1024, 256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024, 16 * 1024 * 1024 }) |size| {
        for (0..3) |mode| {
            var best: i96 = std.math.maxInt(i96);
            var digest: u64 = 0;
            var chunks: u64 = 0;
            var peak: usize = 0;
            for (0..3) |_| {
                var reader: std.Io.Reader = .fixed(data);
                var options: internal.options.Options = .{};
                options.chunk_size = size;
                var parser = try internal.parser.Parser.init(allocator, init.io, &reader, options);
                defer parser.deinit();
                const fixed = try internal.decode.FixedLayout.initForEncoding(&parser.layouts()[0], parser.header().encoding);
                var ctx: Context = .{};
                var run_chunks: u64 = 0;
                const start = std.Io.Clock.awake.now(init.io);
                if (mode == 2) {
                    while (try parser.next()) |value| {
                        var batch = value;
                        defer batch.release();
                        run_chunks += 1;
                        const x = try batch.typedColumn(f32, 0);
                        const y = try batch.typedColumn(f32, 1);
                        const z = try batch.typedColumn(f32, 2);
                        for (x, y, z, 0..) |px, py, pz, i| {
                            ctx.checksum = (ctx.checksum *% 0x100000001b3) ^
                                @as(u32, @bitCast(px)) ^ @as(u32, @bitCast(py)) ^ @as(u32, @bitCast(pz)) ^ i;
                        }
                        peak = @max(peak, parser.raw_buffer.capacity());
                    }
                } else {
                    while (try internal.parser.nextRawChunkForTesting(&parser)) |chunk| {
                        run_chunks += 1;
                        if (mode == 1) {
                            try internal.decode.decodeRange(fixed, chunk.bytes, chunk.record_count, &ctx, Context.consume);
                        } else {
                            ctx.checksum +%= chunk.bytes[0] +% chunk.bytes[chunk.bytes.len - 1];
                        }
                        peak = @max(peak, parser.raw_buffer.capacity());
                    }
                }
                const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
                best = @min(best, elapsed);
                digest ^= ctx.checksum;
                chunks = run_chunks;
            }
            const seconds = @as(f64, @floatFromInt(best)) / 1e9;
            std.debug.print("{d:>5} KiB {s:>10}: {d:.2} GB/s {d:.2} Mrec/s chunks={d} peak={d} checksum={x}\n", .{
                size / 1024,
                switch (mode) {
                    0 => "producer",
                    1 => "record",
                    else => "columns",
                },
                @as(f64, count * 12) / seconds / 1e9,
                @as(f64, count) / seconds / 1e6,
                chunks,
                peak,
                digest,
            });
        }
    }
}
