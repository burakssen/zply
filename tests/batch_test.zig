const std = @import("std");
const ply = @import("zply");
const FragmentingReader = struct {
    source: []const u8,
    pattern: []const usize,
    position: usize = 0,
    index: usize = 0,
    buffer: [1]u8 = undefined,
    base: std.Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },

    fn reader(self: *@This()) *std.Io.Reader {
        self.base.buffer = &self.buffer;
        return &self.base;
    }
    fn stream(base: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("base", base));
        if (self.position == self.source.len) return error.EndOfStream;
        const n = @min(@min(self.source.len - self.position, @backingInt(limit)), self.pattern[self.index % self.pattern.len]);
        const written = try writer.write(self.source[self.position..][0..n]);
        self.position += written;
        self.index += 1;
        return written;
    }
};

const header = "ply\nformat binary_little_endian 1.0\nelement vertex 4\n" ++
    "property float x\nproperty uchar red\nend_header\n";
const body = [_]u8{
    0, 0, 128, 63, 10, 0, 0, 0,   64, 20,
    0, 0, 64,  64, 30, 0, 0, 128, 64, 40,
};

test "multiple leased batches remain independent and later reuse works" {
    var reader: std.Io.Reader = .fixed(header ++ body);
    var options: ply.Options = .{};
    options.chunk_size = 5;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();
    var a = (try parser.next()).?;
    var stale = a;
    var b = (try parser.next()).?;
    try std.testing.expectEqual(@as(f32, 1), (try a.typedColumn(f32, 0))[0]);
    try std.testing.expectEqual(@as(f32, 2), (try b.typedColumn(f32, 0))[0]);
    var c = (try parser.next()).?;
    try std.testing.expectEqual(@as(f32, 3), (try c.typedColumn(f32, 0))[0]);
    try std.testing.expectEqual(@as(u8, 10), (try a.typedColumn(u8, 1))[0]);
    try std.testing.expectError(error.InvalidColumnType, a.typedColumn(f64, 0));
    try std.testing.expectEqual(@as(usize, 1), a.columnByName(parser.header(), "red").?.property_index);
    a.release();
    try std.testing.expect(!stale.isValid());
    try std.testing.expect(!stale.isValid());
    try std.testing.expectError(error.InvalidBatchLease, stale.tryRelease());
    try std.testing.expectEqual(@as(u64, 2), c.info().sequence);
    try std.testing.expectEqual(@as(f32, 2), (try b.typedColumn(f32, 0))[0]);
    b.release();
    c.release();
    var d = (try parser.next()).?;
    try std.testing.expectEqual(@as(f32, 4), (try d.typedColumn(f32, 0))[0]);
    d.release();
    try std.testing.expect((try parser.next()) == null);
}

fn moveParser(parser: ply.Parser) ply.Parser {
    return parser;
}

test "moving parser after acquiring a batch does not move the pool" {
    var reader: std.Io.Reader = .fixed(header ++ body);
    var options: ply.Options = .{};
    options.chunk_size = 5;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    var a = (try parser.next()).?;
    var moved = moveParser(parser);
    defer moved.deinit();
    var b = (try moved.next()).?;
    try std.testing.expectEqual(@as(f32, 1), (try a.typedColumn(f32, 0))[0]);
    try std.testing.expectEqual(@as(f32, 2), (try b.typedColumn(f32, 0))[0]);
    a.release();
    b.release();
}

test "pool grows slots for retained batches without overwriting input" {
    const h = "ply\nformat binary_little_endian 1.0\nelement item 9\nproperty uchar value\nend_header\n";
    const data: [9]u8 = @splat(3);
    var reader: std.Io.Reader = .fixed(h ++ data);
    var options: ply.Options = .{};
    options.chunk_size = 1;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();
    var held: [9]ply.Batch = undefined;
    for (&held) |*slot| slot.* = (try parser.next()).?;
    try std.testing.expect((try parser.next()) == null);
    for (&held) |*slot| slot.release();
}

test "unordered delivery may return later sequences before earlier ones" {
    var reader: std.Io.Reader = .fixed(header ++ body);
    var options: ply.Options = .{};
    options.chunk_size = 5;
    options.preserve_order = false;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
    defer parser.deinit();
    var sequences: [4]u64 = undefined;
    var count: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        sequences[count] = batch.info().sequence;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    var seen: [4]bool = @splat(false);
    for (sequences) |sequence| {
        try std.testing.expect(sequence < 4);
        try std.testing.expect(!seen[sequence]);
        seen[sequence] = true;
    }
}

test "zero property records retain their count" {
    const h = "ply\nformat binary_little_endian 1.0\nelement marker 100\nend_header\n";
    var reader: std.Io.Reader = .fixed(h);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    var batch = (try parser.next()).?;
    try std.testing.expectEqual(@as(usize, 100), batch.info().record_count);
    try std.testing.expectEqual(@as(usize, 0), batch.columnCount());
    batch.release();
    try std.testing.expect((try parser.next()) == null);
}

test "element transitions preserve leased columns and skip empty lists" {
    const source = "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 1\nproperty uchar x\n" ++
        "element empty 0\nproperty list uchar int ids\n" ++
        "element camera 1\nproperty double x\nend_header\n" ++
        [_]u8{ 42, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f };
    var reader: std.Io.Reader = .fixed(source);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    var vertex = (try parser.next()).?;
    var camera = (try parser.next()).?;
    try std.testing.expectEqual(@as(usize, 0), vertex.info().element_index);
    try std.testing.expectEqual(@as(usize, 2), camera.info().element_index);
    try std.testing.expectEqual(@as(u64, 0), camera.info().first_record);
    try std.testing.expectEqual(@as(u64, 1), camera.info().sequence);
    try std.testing.expectEqual(@as(u8, 42), (try vertex.typedColumn(u8, 0))[0]);
    try std.testing.expectEqual(@as(f64, 1), (try camera.f64Column(0))[0]);
    vertex.release();
    camera.release();
    try std.testing.expect((try parser.next()) == null);
}

test "truncated body publishes no batch" {
    var reader: std.Io.Reader = .fixed(header ++ body[0..3].*);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    try std.testing.expectError(error.TruncatedBody, parser.next());
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

test "budget below bootstrap size is rejected before input" {
    const source = "ply\nformat binary_little_endian 1.0\nelement item 1\n" ++
        "property double value\nproperty uchar flag\nend_header\n" ++
        [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 42 };
    var reader: std.Io.Reader = .fixed(source);
    var options: ply.Options = .{};
    options.chunk_size = 1;
    options.memory_budget = 8;
    try std.testing.expectError(error.ResourceLimitExceeded, ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options));
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "public next rejects truncated binary lists and preserves trailing input" {
    const list_source = "ply\nformat binary_little_endian 1.0\n" ++
        "element vertex 1\nproperty uchar x\n" ++
        "element face 1\nproperty list uchar int ids\nend_header\n" ++
        [_]u8{ 9, 1, 2, 3 };
    var reader: std.Io.Reader = .fixed(list_source);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    var batch = (try parser.next()).?;
    try std.testing.expectEqual(@as(u8, 9), (try batch.typedColumn(u8, 0))[0]);
    batch.release();
    // Binary list elements are now supported. This list declares one i32
    // item but provides only three payload bytes, so the error is truncation.
    // Native task admission may read ahead while preparing the first batch:
    // the malformed list may already have reached EOF before this call.
    try std.testing.expectError(error.TruncatedListPayload, parser.next());
    try std.testing.expectEqual(reader.end, reader.seek);
    const consumed_on_failure = reader.seek;
    try std.testing.expectError(error.InvalidProducerState, parser.next());
    try std.testing.expectEqual(consumed_on_failure, reader.seek);

    const trailing = header ++ body ++ "TAIL";
    var reader2: std.Io.Reader = .fixed(trailing);
    var parser2 = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader2, .{});
    defer parser2.deinit();
    var last = (try parser2.next()).?;
    last.release();
    try std.testing.expect((try parser2.next()) == null);
    try std.testing.expectEqualStrings("TAIL", reader2.buffer[reader2.seek..reader2.end]);
}

test "fragmented readers produce the same public batches" {
    const source = header ++ body ++ "TAIL";
    for ([_][]const usize{ &.{1}, &.{ 2, 3, 5, 7 }, &.{ 64, 1, 128, 3 } }) |pattern| {
        var reader: FragmentingReader = .{ .source = source, .pattern = pattern };
        var options: ply.Options = .{};
        options.chunk_size = 5;
        var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, reader.reader(), options);
        defer parser.deinit();
        var count: usize = 0;
        while (try parser.next()) |value| {
            var b = value;
            defer b.release();
            try std.testing.expectEqual(@as(u64, @intCast(count)), b.info().first_record);
            try std.testing.expectEqual(@as(f32, @floatFromInt(count + 1)), (try b.typedColumn(f32, 0))[0]);
            try std.testing.expectEqual(@as(u8, @intCast((count + 1) * 10)), (try b.typedColumn(u8, 1))[0]);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), count);
        try std.testing.expectEqual(header.len + body.len, reader.position);
    }
}

test "all scalar types and floating point bits survive both byte orders" {
    const props = "element mixed 1\nproperty char a\nproperty uchar b\n" ++
        "property short c\nproperty ushort d\nproperty int e\nproperty uint f\n" ++
        "property float g\nproperty double h\nend_header\n";
    const le = "ply\nformat binary_little_endian 1.0\n" ++ props ++
        [_]u8{ 0xff, 0xfe, 0xfe, 0xff, 0x34, 0x12, 0xfd, 0xff, 0xff, 0xff, 0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0x80, 1, 0, 0, 0, 0, 0, 0xf8, 0x7f };
    const be = "ply\nformat binary_big_endian 1.0\n" ++ props ++
        [_]u8{ 0xff, 0xfe, 0xff, 0xfe, 0x12, 0x34, 0xff, 0xff, 0xff, 0xfd, 0x12, 0x34, 0x56, 0x78, 0x80, 0, 0, 0, 0x7f, 0xf8, 0, 0, 0, 0, 0, 1 };
    for ([_][]const u8{ le, be }) |source| {
        var reader: std.Io.Reader = .fixed(source);
        var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
        defer parser.deinit();
        var b = (try parser.next()).?;
        defer b.release();
        try std.testing.expectEqual(@as(usize, 8), b.columnCount());
        try std.testing.expectEqual(@as(i8, -1), (try b.typedColumn(i8, 0))[0]);
        try std.testing.expectEqual(@as(u8, 254), (try b.typedColumn(u8, 1))[0]);
        try std.testing.expectEqual(@as(i16, -2), (try b.typedColumn(i16, 2))[0]);
        try std.testing.expectEqual(@as(u16, 0x1234), (try b.typedColumn(u16, 3))[0]);
        try std.testing.expectEqual(@as(i32, -3), (try b.typedColumn(i32, 4))[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), (try b.typedColumn(u32, 5))[0]);
        try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast((try b.typedColumn(f32, 6))[0])));
        try std.testing.expectEqual(@as(u64, 0x7ff8000000000001), @as(u64, @bitCast((try b.typedColumn(f64, 7))[0])));
    }
}

test "column output matches generic records across batch boundaries" {
    const properties = "element mixed 100\nproperty char a\nproperty uchar b\n" ++
        "property short c\nproperty ushort d\nproperty int e\nproperty uint f\n" ++
        "property float g\nproperty double h\nend_header\n";
    const width = 26;
    for ([_][]const u8{ "little", "big" }) |order| {
        const h = try std.testing.allocator.print("ply\nformat binary_{s}_endian 1.0\n{s}", .{ order, properties });
        defer std.testing.allocator.free(h);
        const source = try std.testing.allocator.alloc(u8, h.len + 100 * width);
        defer std.testing.allocator.free(source);
        @memcpy(source[0..h.len], h);
        var prng = std.Random.DefaultPrng.init(0x5a17);
        prng.random().bytes(source[h.len..]);
        for ([_]usize{ 1, 3, 7, 16, 99, 100 }) |records_per_chunk| {
            var reader: std.Io.Reader = .fixed(source);
            var options: ply.Options = .{};
            options.chunk_size = records_per_chunk * width;
            var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options);
            defer parser.deinit();
            const fixed = try ply.decode.FixedLayout.initForEncoding(&parser.layouts()[0], parser.header().encoding);
            var seen: usize = 0;
            while (try parser.next()) |value| {
                var batch = value;
                defer batch.release();
                for (0..batch.info().record_count) |local| {
                    var expected: [8]ply.ScalarValue = undefined;
                    try ply.decode.decodeRecord(fixed, source[h.len + seen * width ..][0..width], &expected);
                    for (expected, 0..) |reference, p| {
                        const col = batch.column(p).?.values;
                        const actual: ply.ScalarValue = switch (col) {
                            inline else => |slice, tag| @unionInit(ply.ScalarValue, @tagName(tag), slice[local]),
                        };
                        try std.testing.expectEqual(reference.bits(), actual.bits());
                    }
                    seen += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 100), seen);
        }
    }
}

test "output allocation failure never advances body and can be retried" {
    var fail_index: usize = 0;
    var saw_failure = false;
    while (fail_index < 40) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reader: std.Io.Reader = .fixed(header ++ body);
        var parser = ply.Parser.init(failing.allocator(), std.testing.io, &reader, .{}) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        };
        defer parser.deinit();
        const start = reader.seek;
        if (parser.next()) |maybe| {
            var b = maybe.?;
            b.release();
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(start, reader.seek);
            try std.testing.expectEqual(ply.Parser.State.ready, parser.state);
            saw_failure = true;
            failing.fail_index = std.math.maxInt(usize);
            var retry = (try parser.next()).?;
            try std.testing.expectEqual(@as(f32, 1), (try retry.typedColumn(f32, 0))[0]);
            retry.release();
        }
    }
    try std.testing.expect(saw_failure);
}

test "steady state reuses output without additional allocations" {
    const h = "ply\nformat binary_little_endian 1.0\nelement item 101\nproperty uchar value\nend_header\n";
    const data: [101]u8 = @splat(7);
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader: std.Io.Reader = .fixed(h ++ data);
    var options: ply.Options = .{};
    options.chunk_size = 1;
    var parser = try ply.Parser.init(allocator.allocator(), std.testing.io, &reader, options);
    defer parser.deinit();
    var first = (try parser.next()).?;
    first.release();
    const allocations = allocator.allocations;
    const bytes = allocator.allocated_bytes;
    var count: usize = 1;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        try std.testing.expectEqual(@as(u8, 7), (try batch.typedColumn(u8, 0))[0]);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 101), count);
    try std.testing.expectEqual(allocations, allocator.allocations);
    try std.testing.expectEqual(bytes, allocator.allocated_bytes);
}

const generated_header = "ply\nformat binary_little_endian 1.0\nelement vertex 3000000\n" ++
    "property double x\nproperty double y\nproperty double z\nend_header\n";
const GeneratedReader = struct {
    base: std.Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
    buffer: [1]u8 = undefined,
    position: usize = 0,

    fn stream(base: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("base", base));
        const remaining = generated_header.len + 3_000_000 * 24 - self.position;
        if (remaining == 0) return error.EndOfStream;
        const wanted = @min(remaining, @backingInt(limit));
        var total: usize = 0;
        while (total < wanted) {
            if (self.position < generated_header.len) {
                const n = @min(wanted - total, generated_header.len - self.position);
                const written = try writer.write(generated_header[self.position..][0..n]);
                self.position += written;
                total += written;
                if (written < n) break;
            } else {
                const offset = self.position - generated_header.len;
                const index = offset / 24;
                const within = offset % 24;
                const x: f64 = @floatFromInt(index);
                var record: [24]u8 = undefined;
                std.mem.writeInt(u64, record[0..8], @bitCast(x), .little);
                std.mem.writeInt(u64, record[8..16], @bitCast(x * 2), .little);
                std.mem.writeInt(u64, record[16..24], @bitCast(-x), .little);
                const n = @min(wanted - total, 24 - within);
                const written = try writer.write(record[within..][0..n]);
                self.position += written;
                total += written;
                if (written < n) break;
            }
        }
        return total;
    }
};

test "three million generated records stream through reusable batches" {
    var source: GeneratedReader = .{};
    source.base.buffer = &source.buffer;
    var options: ply.Options = .{};
    options.chunk_size = 64 * 1024;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &source.base, options);
    defer parser.deinit();
    var seen: u64 = 0;
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        const x = try batch.f64Column(0);
        const y = try batch.f64Column(1);
        const z = try batch.f64Column(2);
        try std.testing.expectEqual(seen, batch.info().first_record);
        for (x, y, z) |px, py, pz| {
            const expected: f64 = @floatFromInt(seen);
            try std.testing.expectEqual(expected, px);
            try std.testing.expectEqual(expected * 2, py);
            try std.testing.expectEqual(-expected, pz);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(u64, 3_000_000), seen);
    try std.testing.expect(parser.raw_buffer.capacity() <= options.chunk_size);
}
