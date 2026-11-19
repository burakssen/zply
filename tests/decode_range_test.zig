//! Multi-record traversal tests (Task 3.9): fixed-stride ranges,
//! explicit counts, zero-width logical records, checked range
//! arithmetic, and consumer-error propagation.
//!
//! Uses the internals universe exclusively.

const std = @import("std");
const support = @import("decode_support.zig");

const decode = support.decode;
const types = support.types;
const ScalarValue = support.ScalarValue;

test "one and two consecutive records decode in order" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 2\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    // Records: (1,2,3) and (4,5,6).
    const bits_x = [2]u32{ 0x3F800000, 0x40800000 };
    const bits_y = [2]u32{ 0x40000000, 0x40A00000 };
    const bits_z = [2]u32{ 0x40400000, 0x40C00000 };
    var bytes: [24]u8 = undefined;
    for (0..2) |ri| {
        const record = bytes[ri * 12 ..][0..12];
        std.mem.writeInt(u32, record[0..4], bits_x[ri], .little);
        std.mem.writeInt(u32, record[4..8], bits_y[ri], .little);
        std.mem.writeInt(u32, record[8..12], bits_z[ri], .little);
    }

    const Collector = struct {
        decoded: u64 = 0,
        values: [2][3]f32 = undefined,

        fn consume(self: *@This(), record_index: u64, view: decode.RecordView) anyerror!void {
            var values: [3]ScalarValue = undefined;
            try view.decodeAll(&values);
            self.values[record_index][0] = values[0].f32;
            self.values[record_index][1] = values[1].f32;
            self.values[record_index][2] = values[2].f32;
            self.decoded += 1;
        }
    };

    // One record: only the first 12 bytes are touched.
    var one = Collector{};
    try decode.decodeRange(fixed, &bytes, 1, &one, Collector.consume);
    try std.testing.expectEqual(@as(u64, 1), one.decoded);
    try std.testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, one.values[0]);

    // Two records: exact order preserved.
    var two = Collector{};
    try decode.decodeRange(fixed, &bytes, 2, &two, Collector.consume);
    try std.testing.expectEqual(@as(u64, 2), two.decoded);
    try std.testing.expectEqual([3]f32{ 4.0, 5.0, 6.0 }, two.values[1]);
}

test "1,000 records decode with per-index deterministic values" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1000\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    // x_i = i, y_i = 2i, z_i = -i — exactly representable f32 for these
    // small indices.
    const count: u32 = 1000;
    var bytes: [1000 * 12]u8 = undefined;
    for (0..count) |i| {
        const record = bytes[i * 12 ..][0..12];
        std.mem.writeInt(u32, record[0..4], @bitCast(@as(f32, @floatFromInt(i))), .little);
        std.mem.writeInt(u32, record[4..8], @bitCast(@as(f32, @floatFromInt(2 * i))), .little);
        std.mem.writeInt(u32, record[8..12], @bitCast(@as(f32, @floatFromInt(-@as(i32, @intCast(i))))), .little);
    }

    const Verifier = struct {
        visits: u64 = 0,

        fn consume(self: *@This(), record_index: u64, view: decode.RecordView) anyerror!void {
            var values: [3]ScalarValue = undefined;
            try view.decodeAll(&values);
            const i: i64 = @intCast(record_index);
            try std.testing.expectEqual(@as(f32, @floatFromInt(i)), values[0].f32);
            try std.testing.expectEqual(@as(f32, @floatFromInt(2 * i)), values[1].f32);
            try std.testing.expectEqual(@as(f32, @floatFromInt(-i)), values[2].f32);
            self.visits += 1;
        }
    };

    var verifier = Verifier{};
    try decode.decodeRange(fixed, &bytes, count, &verifier, Verifier.consume);
    try std.testing.expectEqual(@as(u64, 1000), verifier.visits);
}

test "record totals that are not powers of two decode without stride errors" {
    // 3 × 15, 7 × 11, 13 × 24 bytes: non-power-of-two totals catch wrong
    // stride computations.
    const configs = .{
        .{ .records = 3, .size = 15 },
        .{ .records = 7, .size = 11 },
        .{ .records = 13, .size = 24 },
    };

    inline for (configs) |config| {
        // Build a header of `config.size` uchar properties per record.
        var header_buf: [1024]u8 = undefined;
        var cursor: usize = 0;
        cursor += (std.fmt.bufPrint(
            header_buf[cursor..],
            "ply\nformat binary_little_endian 1.0\nelement vertex {d}\n",
            .{config.records},
        ) catch unreachable).len;
        for (0..config.size) |pi| {
            cursor += (std.fmt.bufPrint(
                header_buf[cursor..],
                "property uchar p{d}\n",
                .{pi},
            ) catch unreachable).len;
        }
        cursor += (std.fmt.bufPrint(header_buf[cursor..], "end_header\n", .{}) catch unreachable).len;

        var storage = try support.parseHeader(header_buf[0..cursor]);
        defer storage.deinit();
        const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);
        try std.testing.expectEqual(@as(usize, config.size), fixed.record_size);

        const total = config.records * config.size;
        var bytes: [total]u8 = undefined;
        // Deterministic content: byte (i,k) = (i*31 + k) truncated.
        for (0..config.records) |i| {
            for (0..config.size) |k| {
                bytes[i * config.size + k] = @truncate(i * 31 + k);
            }
        }

        const Checker = struct {
            fn consume(_: *void, record_index: u64, view: decode.RecordView) anyerror!void {
                // Every byte of record i must equal (i*31 + k).
                for (0..config.size) |k| {
                    const expected: u8 = @truncate(@as(u64, record_index) * 31 + k);
                    const actual = try view.get(k);
                    try std.testing.expectEqual(ScalarValue{ .u8 = expected }, actual);
                }
            }
        };

        var no_context: void = {};
        try decode.decodeRange(fixed, &bytes, config.records, &no_context, Checker.consume);
    }
}

test "empty input with zero records succeeds; nonzero records fail" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 2\n" ++
            "property float x\n" ++
            "property uchar red\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    const Counter = struct {
        visits: u64 = 0,
        fn consume(self: *@This(), _: u64, _: decode.RecordView) anyerror!void {
            self.visits += 1;
        }
    };

    var zero = Counter{};
    try decode.decodeRange(fixed, "", 0, &zero, Counter.consume);
    try std.testing.expectEqual(@as(u64, 0), zero.visits);

    var nonzero = Counter{};
    try std.testing.expectError(
        error.InsufficientBytes,
        decode.decodeRange(fixed, "", 1, &nonzero, Counter.consume),
    );
    try std.testing.expectEqual(@as(u64, 0), nonzero.visits);
}

test "trailing bytes beyond the declared range are left untouched" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 2\n" ++
            "property float x\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var bytes: [20]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, bytes[4..8], @bitCast(@as(f32, 2.0)), .little);
    for (8..20) |i| bytes[i] = 0xA5; // trailing body that is not ours

    const Tail = struct {
        fn consume(_: *@This(), record_index: u64, view: decode.RecordView) anyerror!void {
            const value = try view.get(0);
            const expected: f32 = if (record_index == 0) 1.0 else 2.0;
            try std.testing.expectEqual(expected, value.f32);
        }
    };
    var context: Tail = .{};
    try decode.decodeRange(fixed, &bytes, 2, &context, Tail.consume);

    // The trailing bytes are unmodified and untouched.
    for (8..20) |i| try std.testing.expectEqual(@as(u8, 0xA5), bytes[i]);
}

test "a truncated final record is rejected cleanly" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 3\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "property float z\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    // 3 records of 12 bytes expected; the last one has only 5 bytes.
    var bytes: [29]u8 = @splat(0);
    const Counter = struct {
        visits: u64 = 0,
        fn consume(self: *@This(), _: u64, _: decode.RecordView) anyerror!void {
            self.visits += 1;
        }
    };
    var counter = Counter{};
    try std.testing.expectError(
        error.InsufficientBytes,
        decode.decodeRange(fixed, &bytes, 3, &counter, Counter.consume),
    );
    // Nothing was visited: the range is validated up front.
    try std.testing.expectEqual(@as(u64, 0), counter.visits);
}

test "a huge count overflows the checked range into SizeOverflow" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 1\n" ++
            "property float x\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    const Counter = struct {
        fn consume(_: *@This(), _: u64, _: decode.RecordView) anyerror!void {}
    };
    var context: Counter = .{};
    // max u64 count × 4-byte record overflows u64.
    try std.testing.expectError(
        error.SizeOverflow,
        decode.decodeRange(fixed, "", std.math.maxInt(u64), &context, Counter.consume),
    );
}

test "zero-width records visit every logical record without division" {
    var storage = try support.parseHeader(
        "ply\nformat binary_little_endian 1.0\nelement empty 1000\nend_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    try std.testing.expectEqual(@as(usize, 0), fixed.record_size);

    const Counter = struct {
        first: u64 = std.math.maxInt(u64),
        last: u64 = 0,
        visits: u64 = 0,

        fn consume(self: *@This(), record_index: u64, view: decode.RecordView) anyerror!void {
            if (self.visits == 0) self.first = record_index;
            self.last = record_index;
            self.visits += 1;
            // Empty view, empty values, empty bytes.
            try std.testing.expectEqual(@as(usize, 0), view.propertyCount());
            try std.testing.expectEqual(@as(usize, 0), view.bytes.len);
            var none: [0]ScalarValue = .{};
            try view.decodeAll(&none);
        }
    };

    var counter = Counter{};
    try decode.decodeRange(fixed, "", 1000, &counter, Counter.consume);
    try std.testing.expectEqual(@as(u64, 1000), counter.visits);
    try std.testing.expectEqual(@as(u64, 0), counter.first);
    try std.testing.expectEqual(@as(u64, 999), counter.last);
}

test "recordCountForRange derives counts only from exact nonzero ranges" {
    try std.testing.expectEqual(@as(u64, 3), try decode.recordCountForRange(45, 15));
    try std.testing.expectEqual(@as(u64, 7), try decode.recordCountForRange(77, 11));
    try std.testing.expectEqual(@as(u64, 13), try decode.recordCountForRange(312, 24));
    try std.testing.expectEqual(@as(u64, 0), try decode.recordCountForRange(0, 15));

    // Trailing bytes are an error, never silently ignored.
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode.recordCountForRange(46, 15),
    );
    // A zero-width record cannot have its count derived.
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode.recordCountForRange(0, 0),
    );
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode.recordCountForRange(100, 0),
    );
}

test "the consumer's own error aborts and propagates" {
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 4\n" ++
            "property float x\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var bytes: [16]u8 = @splat(0);

    const Aborter = struct {
        visited: u64 = 0,

        fn consume(self: *@This(), record_index: u64, _: decode.RecordView) anyerror!void {
            self.visited += 1;
            if (record_index == 2) return error.CustomAbort;
        }
    };

    var aborter = Aborter{};
    try std.testing.expectError(
        error.CustomAbort,
        decode.decodeRange(fixed, &bytes, 4, &aborter, Aborter.consume),
    );
    try std.testing.expectEqual(@as(u64, 3), aborter.visited);
}

test "disjoint ranges decode independently (concurrency-readiness property)" {
    // Two disjoint slices and disjoint output storage: the same layout
    // decodes both without shared state.
    var storage = try support.parseHeader(
        "ply\n" ++
            "format binary_little_endian 1.0\n" ++
            "element vertex 2\n" ++
            "property float x\n" ++
            "property float y\n" ++
            "end_header\n",
    );
    defer storage.deinit();
    const fixed = try support.fixedLayout(&storage, 0, .binary_little_endian);

    var buffer_a: [16]u8 = undefined;
    var buffer_b: [16]u8 = undefined;
    for (0..2) |i| {
        std.mem.writeInt(u32, buffer_a[i * 8 ..][0..4], @bitCast(@as(f32, @floatFromInt(i))), .little);
        std.mem.writeInt(u32, buffer_a[i * 8 + 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(100 + i))), .little);
        std.mem.writeInt(u32, buffer_b[i * 8 ..][0..4], @bitCast(@as(f32, @floatFromInt(1000 + i))), .little);
        std.mem.writeInt(u32, buffer_b[i * 8 + 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(2000 + i))), .little);
    }

    const Sink = struct {
        sum_bits: u64 = 0,

        fn consume(self: *@This(), _: u64, view: decode.RecordView) anyerror!void {
            var values: [2]ScalarValue = undefined;
            try view.decodeAll(&values);
            self.sum_bits ^= values[0].bits() ^ values[1].bits();
        }
    };

    var sink_a = Sink{};
    var sink_b = Sink{};
    try decode.decodeRange(fixed, &buffer_a, 2, &sink_a, Sink.consume);
    try decode.decodeRange(fixed, &buffer_b, 2, &sink_b, Sink.consume);

    // Distinct data produces distinct checksums; each buffer's checksum
    // is deterministic.
    try std.testing.expect(sink_a.sum_bits != sink_b.sum_bits);
}
