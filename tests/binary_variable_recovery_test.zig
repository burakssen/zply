//! Phase 10 Milestone 6C: deterministic allocator-failure recovery.
//!
//! Failure injection starts AFTER Parser.init so it can interrupt structural
//! staging, boundary allocation, output preparation or task admission. The
//! caller then removes the injected fault and must receive every original
//! record once, without rewinding the borrowed Reader.
const std = @import("std");
const internal = @import("zply_internals");
const Parser = internal.parser.Parser;
const Property = internal.property.Property;
const Element = internal.element.Element;
const Header = internal.header.Header;
const Layout = internal.layout.ElementLayout;

const properties = [_]Property{
    Property.list("indices", .u8, .i32),
    Property.scalar("score", .f32),
    Property.list("labels", .u16, .u8),
};
const limits: internal.binary_boundary.Limits = .{
    .max_record_bytes = 1024,
    .max_list_items_per_record = 256,
};

fn layouts() ![]Layout {
    const elements = [_]Element{.{ .name = "face", .count = 3, .properties = &properties }};
    const header: Header = .{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    return internal.layout.compileSchema(std.testing.allocator, &header);
}

fn freeLayouts(compiled: []Layout) void {
    for (compiled) |layout| std.testing.allocator.free(layout.properties);
    std.testing.allocator.free(compiled);
}

// Three variable records: [10,11]/[7,8,9], []/[5], [12]/[].
const body = [_]u8{
    2, 10, 0, 0, 0, 11, 0, 0, 0, 0, 0, 128, 63, 3, 0, 7, 8, 9,
    0, 0, 0, 0, 64, 1, 0, 5,
    1, 12, 0, 0, 0, 0, 0, 64, 64, 0, 0,
    0xed,
};

test "binary variable chunk builder survives allocation failure at each staging site" {
    const compiled = try layouts();
    defer freeLayouts(compiled);
    const record_offsets = [_]usize{ 0, 18, 26, 37 };
    const per_record_counts = [_][3]usize{ .{ 2, 0, 3 }, .{ 0, 0, 1 }, .{ 1, 0, 0 } };
    var observed_failure = false;
    var observed_success = false;
    for (0..75) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var source: std.Io.Reader = .fixed(&body);
        var builder: internal.binary_chunk_builder.Builder = .{};
        defer builder.deinit(failing.allocator());

        var next_record: usize = 0;
        while (next_record < 3) {
            var chunk: internal.binary_chunk_builder.Chunk = undefined;
            while (true) {
                const result = builder.fill(failing.allocator(), &source, &compiled[0], .little, limits,
                    24, @intCast(next_record), @intCast(3 - next_record)) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    observed_failure = true;
                    // No rewind: a record may be only partially consumed,
                    // or one or more complete records may be staged already.
                    failing.fail_index = std.math.maxInt(usize);
                    continue;
                };
                chunk = result orelse return error.UnexpectedEndOfInput;
                break;
            }
            try std.testing.expectEqual(@as(u64, @intCast(next_record)), chunk.first_record);
            try std.testing.expectEqual(@as(u64, @intCast(record_offsets[next_record])), chunk.first_body_byte_offset);
            try std.testing.expect(chunk.record_count > 0);
            try std.testing.expectEqual(chunk.record_count + 1, chunk.offsets.len);
            var totals = [_]usize{ 0, 0, 0 };
            for (0..chunk.record_count) |row| {
                const index = next_record + row;
                try std.testing.expect(index < 3);
                const expected = body[record_offsets[index]..record_offsets[index + 1]];
                try std.testing.expectEqualSlices(u8, expected, chunk.bytes[chunk.offsets[row]..chunk.offsets[row + 1]]);
                for (&totals, per_record_counts[index]) |*sum, items| sum.* += items;
            }
            try std.testing.expectEqualSlices(usize, &totals, chunk.list_item_totals);
            builder.consume();
            next_record += chunk.record_count;
        }
        try std.testing.expectEqual(@as(u8, 0xed), try source.takeByte());
        observed_success = true;
    }
    try std.testing.expect(observed_failure);
    try std.testing.expect(observed_success);
}

fn sourceFixture(allocator: std.mem.Allocator, count: usize, endian: std.builtin.Endian) ![]u8 {
    const encoding = if (endian == .little) "binary_little_endian" else "binary_big_endian";
    const header = try std.fmt.allocPrint(allocator,
        "ply\nformat {s} 1.0\nelement face {d}\nproperty list uchar uint indices\nproperty float score\nend_header\n",
        .{ encoding, count },
    );
    defer allocator.free(header);
    // Four uint indices + one f32 scalar per record.
    const record_width: usize = 1 + 4 * 4 + 4;
    const bytes = try allocator.alloc(u8, header.len + count * record_width + 2);
    @memcpy(bytes[0..header.len], header);
    var cursor = header.len;
    for (0..count) |i| {
        bytes[cursor] = 4;
        cursor += 1;
        for (0..4) |j| {
            std.mem.writeInt(u32, bytes[cursor..][0..4], @intCast(i * 4 + j), endian);
            cursor += 4;
        }
        const score: f32 = @floatFromInt(i);
        std.mem.writeInt(u32, bytes[cursor..][0..4], @bitCast(score), endian);
        cursor += 4;
    }
    bytes[cursor] = 0xa5;
    bytes[cursor + 1] = 0x5a;
    return bytes;
}

test "binary variable Parser.next resumes exactly once across injected body allocation failures" {
    const count: usize = 257;
    var failures: usize = 0;
    var post_body_failures: usize = 0;
    inline for (.{ .little, .big }) |endian| {
        const fixture = try sourceFixture(std.testing.allocator, count, endian);
        defer std.testing.allocator.free(fixture);
        // Test every early admission allocation and also successful paths.
        for (0..110) |offset| {
            var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var reader: std.Io.Reader = .fixed(fixture);
            var parser = try Parser.init(backing.allocator(), std.testing.io, &reader, .{
                // One staged task keeps an injected backing-allocation
                // failure observable directly, rather than deferring it
                // behind already-running tasks (a terminal error path).
                .chunk_size = 64 * 1024,
                .memory_budget = 2 * 1024 * 1024,
            });
            var delivered: usize = 0;
            var fault_seen = false;
            const body_start = reader.seek;
            backing.fail_index = backing.alloc_index + offset;
            while (true) {
                const maybe = parser.next() catch |err| {
                    // Underlying allocator failure can surface from staging,
                    // decoded-output allocation or task registration.
                    try std.testing.expect(err == error.OutOfMemory or err == error.BatchCapacityUnavailable);
                    try std.testing.expect(!fault_seen);
                    fault_seen = true;
                    failures += 1;
                    if (reader.seek > body_start) post_body_failures += 1;
                    backing.fail_index = std.math.maxInt(usize);
                    try std.testing.expect(parser.memoryStats().peak_total_bytes <= parser.memoryStats().budget_bytes);
                    continue;
                } orelse break;
                var batch = maybe;
                defer batch.release();
                const info = batch.info();
                try std.testing.expectEqual(@as(u64, @intCast(delivered)), info.first_record);
                const indices = try batch.listColumn(0);
                const scores = try batch.typedColumn(f32, 1);
                for (0..info.record_count) |row| {
                    const i = delivered + row;
                    try std.testing.expect(i < count);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(i)), scores[row]);
                    const values = indices.row(row).?.u32;
                    try std.testing.expectEqual(@as(usize, 4), values.len);
                    for (values, 0..) |item, j| try std.testing.expectEqual(@as(u32, @intCast(i * 4 + j)), item);
                }
                delivered += info.record_count;
                try std.testing.expect(parser.memoryStats().peak_total_bytes <= parser.memoryStats().budget_bytes);
            }
            try std.testing.expectEqual(count, delivered);
            try std.testing.expectEqual(@as(u8, 0xa5), try reader.takeByte());
            try std.testing.expectEqual(@as(u8, 0x5a), try reader.takeByte());
            try std.testing.expectEqual(@as(usize, 0), parser.executionStats().active_decodes);
            parser.deinit();
            try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
        }
    }
    try std.testing.expect(failures > 0);
    try std.testing.expect(post_body_failures > 0);
}

test "binary variable deterministic malformed corpus rejects excess counts and truncation" {
    var prng = std.Random.DefaultPrng.init(0x106c2026);
    const random = prng.random();
    inline for (.{ .little, .big }) |endian| {
        const header = if (endian == .little)
            "ply\nformat binary_little_endian 1.0\nelement face 1\nproperty list ushort int indices\nproperty float score\nend_header\n"
        else
            "ply\nformat binary_big_endian 1.0\nelement face 1\nproperty list ushort int indices\nproperty float score\nend_header\n";
        var data: [256]u8 = undefined;
        @memcpy(data[0..header.len], header);
        for (0..96) |trial| {
            const items = random.intRangeAtMost(usize, 0, 8);
            const body_start = header.len;
            std.mem.writeInt(u16, data[body_start..][0..2], @intCast(items), endian);
            var cursor = body_start + 2;
            for (0..items) |j| {
                std.mem.writeInt(i32, data[cursor..][0..4], @intCast(trial * 17 + j), endian);
                cursor += 4;
            }
            const score: f32 = @floatFromInt(trial);
            std.mem.writeInt(u32, data[cursor..][0..4], @bitCast(score), endian);
            cursor += 4;
            const opts: internal.options.Options = .{
                .chunk_size = 64,
                .memory_budget = 512 * 1024,
                .limits = .{ .max_list_items_per_record = 8, .max_record_bytes = 1024 },
            };
            // Valid corpus: independently generated row and items.
            {
                var source: std.Io.Reader = .fixed(data[0..cursor]);
                var parser = try Parser.init(std.testing.allocator, std.testing.io, &source, opts);
                defer parser.deinit();
                var batch = (try parser.next()) orelse return error.UnexpectedEndOfInput;
                defer batch.release();
                const values = (try batch.listColumn(0)).row(0).?.i32;
                try std.testing.expectEqual(items, values.len);
                for (values, 0..) |v, j| try std.testing.expectEqual(@as(i32, @intCast(trial * 17 + j)), v);
                try std.testing.expectEqual(score, (try batch.typedColumn(f32, 1))[0]);
                try std.testing.expect((try parser.next()) == null);
            }
            // Invalid count must be rejected from the two structural bytes,
            // before attempting to reserve or read any declared list payload.
            {
                std.mem.writeInt(u16, data[body_start..][0..2], 9, endian);
                var source: std.Io.Reader = .fixed(data[0..cursor]);
                var parser = try Parser.init(std.testing.allocator, std.testing.io, &source, opts);
                defer parser.deinit();
                try std.testing.expectError(error.ListTooLarge, parser.next());
                try std.testing.expect(parser.binaryDiagnostic() != null);
            }
            // Restore the valid count, then truncate inside the declared
            // list when nonempty or inside the following scalar otherwise.
            {
                std.mem.writeInt(u16, data[body_start..][0..2], @intCast(items), endian);
                const truncated = if (items == 0) body_start + 2 else body_start + 2 + (items - 1) * 4;
                var source: std.Io.Reader = .fixed(data[0..truncated]);
                var parser = try Parser.init(std.testing.allocator, std.testing.io, &source, opts);
                defer parser.deinit();
                const expected = if (items == 0) error.TruncatedRecord else error.TruncatedListPayload;
                try std.testing.expectError(expected, parser.next());
                try std.testing.expect(parser.binaryDiagnostic() != null);
            }
        }
    }
}
