//! Comparable generic-record, direct-column, and Parser.next() benchmarks.
//! Warm in-memory input, not a storage or cold-cache benchmark.
const std = @import("std");
const z = @import("zply_internals");
const count = 200_000;

const Config = struct { name: []const u8, properties: []const u8, width: usize };
const configs = [_]Config{
    .{ .name = "xyz f32", .properties = "property float x\nproperty float y\nproperty float z\n", .width = 12 },
    .{ .name = "xyz f64", .properties = "property double x\nproperty double y\nproperty double z\n", .width = 24 },
    .{ .name = "xyzrgb f32", .properties = "property float x\nproperty float y\nproperty float z\nproperty uchar r\nproperty uchar g\nproperty uchar b\n", .width = 15 },
    .{ .name = "xyzrgb f64", .properties = "property double x\nproperty double y\nproperty double z\nproperty uchar r\nproperty uchar g\nproperty uchar b\n", .width = 27 },
    .{ .name = "scalar u8", .properties = "property uchar v\n", .width = 1 },
    .{ .name = "mixed", .properties = "property char a\nproperty ushort b\nproperty int c\nproperty float d\nproperty double e\n", .width = 19 },
    .{ .name = "wide 20", .properties = "property uchar a0\nproperty uchar a1\nproperty uchar a2\nproperty uchar a3\nproperty uchar a4\nproperty uchar a5\nproperty uchar a6\nproperty uchar a7\nproperty uchar a8\nproperty uchar a9\nproperty uchar a10\nproperty uchar a11\nproperty uchar a12\nproperty uchar a13\nproperty uchar a14\nproperty uchar a15\nproperty uchar a16\nproperty uchar a17\nproperty uchar a18\nproperty uchar a19\n", .width = 20 },
};

fn mix(hash: *u64, bits: u64) void {
    hash.* = (hash.* ^ bits) *% 0x100000001b3;
}

fn consumeBatch(batch: *const z.parser.Batch, hash: *u64) void {
    // Equivalent record/property traversal to the generic-record baseline.
    for (0..batch.info().record_count) |i| {
        for (0..batch.columnCount()) |p| {
            const values = batch.column(p).?.values;
            const v: z.decode.ScalarValue = switch (values) {
                inline else => |slice, tag| @unionInit(z.decode.ScalarValue, @tagName(tag), slice[i]),
            };
            mix(hash, v.bits());
        }
    }
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("Column benchmark: 200k records, warm memory, best of 3; includes output checksum traversal\n", .{});
    for (configs) |config| {
        for ([_]std.builtin.Endian{ .little, .big }) |endian| {
            const header = try init.gpa.print("ply\nformat binary_{s}_endian 1.0\nelement item {d}\n{s}end_header\n", .{
                if (endian == .little) "little" else "big", count, config.properties,
            });
            defer init.gpa.free(header);
            const data = try init.gpa.alloc(u8, header.len + count * config.width);
            defer init.gpa.free(data);
            @memcpy(data[0..header.len], header);
            for (data[header.len..], 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
            var expected_digest: ?u64 = null;
            for (0..4) |mode| {
                var best: i96 = std.math.maxInt(i96);
                var checksum: u64 = 0;
                var allocations: usize = 0;
                for (0..3) |_| {
                    var tracking = std.testing.FailingAllocator.init(init.gpa, .{});
                    var reader: std.Io.Reader = .fixed(data);
                    var parser = try z.parser.Parser.init(tracking.allocator(), init.io, &reader, .{});
                    defer parser.deinit();
                    const layout = &parser.layouts()[0];
                    const fixed = try z.decode.FixedLayout.init(layout, endian);
                    var digest: u64 = 0xcbf29ce484222325;
                    var pool: ?*z.batch_storage.Pool = null;
                    var slot: usize = undefined;
                    if (mode == 1 or mode == 2) {
                        pool = try z.batch_storage.Pool.create(tracking.allocator());
                        slot = try pool.?.acquire(layout, count);
                    }
                    defer if (pool) |p| p.destroy();
                    const alloc_before = tracking.allocations;
                    const start = std.Io.Clock.awake.now(init.io);
                    switch (mode) {
                        0 => {
                            var values: [20]z.decode.ScalarValue = undefined;
                            for (0..count) |i| {
                                const record = data[header.len + i * config.width ..][0..config.width];
                                try z.decode.decodeRecord(fixed, record, values[0..layout.properties.len]);
                                for (values[0..layout.properties.len]) |v| mix(&digest, v.bits());
                            }
                        },
                        1, 2 => {
                            if (mode == 1) {
                                try pool.?.decode(slot, layout, endian, data[header.len..], count);
                            } else {
                                try pool.?.decodePropertyMajor(slot, layout, endian, data[header.len..], count);
                            }
                            var b = pool.?.publish(slot, .{ .element_index = 0, .first_record = 0, .record_count = count, .sequence = 0 });
                            consumeBatch(&b, &digest);
                            b.release();
                        },
                        else => while (try parser.next()) |value| {
                            var b = value;
                            consumeBatch(&b, &digest);
                            b.release();
                        },
                    }
                    const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
                    best = @min(best, elapsed);
                    checksum = digest;
                    allocations = tracking.allocations - alloc_before;
                }
                if (expected_digest) |expected| {
                    if (checksum != expected) return error.BenchmarkChecksumMismatch;
                } else expected_digest = checksum;
                const ns: f64 = @floatFromInt(best);
                std.debug.print("{s:<12} {s} {s:<10} {d:>7.2} ns/record {d:>6.2} GB/s {d:>7.2} Mrec/s payload={d} allocs={d} digest={x}\n", .{
                    config.name,                 if (endian == .little) "LE" else "BE",
                    switch (mode) {
                        0 => "records",
                        1 => "direct",
                        2 => "property",
                        else => "next",
                    },
                    ns / count,                  @as(f64, @floatFromInt(count * config.width)) / ns,
                    @as(f64, count) * 1000 / ns, count * config.width,
                    allocations,                 checksum,
                });
            }
        }
    }
}
