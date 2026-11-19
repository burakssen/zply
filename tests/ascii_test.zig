//! Phase 8: sequential strict ASCII PLY through unchanged Parser.next().
const std = @import("std");
const z = @import("zply");

const all_types =
    "ply\nformat ascii 1.0\nelement datum 2\n" ++
    "property char a\nproperty uchar b\nproperty short c\nproperty ushort d\n" ++
    "property int e\nproperty uint f\nproperty float g\nproperty double h\nend_header\n" ++
    "-128 255 -32768 65535 -2147483648 4294967295 -0.0 1.25e2\n" ++
    "+127 0 32767 0 2147483647 0 .5 -2.5\nTAIL";

test "strict ASCII decodes all canonical scalar types without changing public API" {
    var reader: std.Io.Reader = .fixed(all_types);
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 4096 });
    defer parser.deinit();
    var batch = (try parser.next()).?;
    defer batch.release();
    try std.testing.expectEqual(@as(usize, 2), batch.info().record_count);
    try std.testing.expectEqual(@as(i8, -128), (try batch.typedColumn(i8, 0))[0]);
    try std.testing.expectEqual(@as(u8, 255), (try batch.typedColumn(u8, 1))[0]);
    try std.testing.expectEqual(@as(i16, -32768), (try batch.typedColumn(i16, 2))[0]);
    try std.testing.expectEqual(@as(u16, 65535), (try batch.typedColumn(u16, 3))[0]);
    try std.testing.expectEqual(@as(i32, -2147483648), (try batch.typedColumn(i32, 4))[0]);
    try std.testing.expectEqual(@as(u32, 4294967295), (try batch.typedColumn(u32, 5))[0]);
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast((try batch.typedColumn(f32, 6))[0])));
    try std.testing.expectEqual(@as(f64, 125.0), (try batch.typedColumn(f64, 7))[0]);
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expectEqual(@as(u8, 'T'), try reader.takeByte());
}

test "ASCII list columns preserve typed values, offsets, mixed properties and empty lists" {
    const data = "ply\nformat ascii 1.0\nelement face 3\n" ++
        "property float score\nproperty list uchar int indices\n" ++
        "property double time\nproperty list ushort float weights\nend_header\n" ++
        "0.5 3 10 11 12 2.0 2 1.5 2.5\n" ++
        "1.0 0 3.0 0\n" ++
        "2.0 4 0 1 2 3 4.0 1 7.0\n";
    var reader: std.Io.Reader = .fixed(data);
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 64 });
    defer parser.deinit();
    for (0..3) |i| {
        var batch = (try parser.next()).?;
        defer batch.release();
        try std.testing.expectEqual(@as(u64, @intCast(i)), batch.info().first_record);
        try std.testing.expectEqual(@as(usize, 1), batch.info().record_count);
        try std.testing.expectEqual(@as(usize, 4), batch.columnCount());
        const indices = try batch.listColumn(1);
        const weights = try batch.listColumn(3);
        try std.testing.expectEqual(@as(usize, 2), indices.offsets.len);
        try std.testing.expectEqual(@as(usize, 2), weights.offsets.len);
        // Out-of-range access must be total even at the maximum usize.
        try std.testing.expect(indices.row(1) == null);
        try std.testing.expect(indices.row(std.math.maxInt(usize)) == null);
        try std.testing.expectEqual(@as(usize, 0), indices.offsets[0]);
        try std.testing.expectEqual(@as(usize, 0), weights.offsets[0]);
        const expected_count: usize = switch (i) {
            0 => 3,
            1 => 0,
            else => 4,
        };
        try std.testing.expectEqual(expected_count, indices.offsets[1]);
        if (i == 0) {
            try std.testing.expectEqualSlices(i32, &.{ 10, 11, 12 }, indices.row(0).?.i32);
            try std.testing.expectEqualSlices(f32, &.{ 1.5, 2.5 }, weights.row(0).?.f32);
        } else if (i == 1) {
            try std.testing.expectEqual(@as(usize, 0), indices.row(0).?.i32.len);
        } else {
            try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, indices.row(0).?.i32);
            try std.testing.expectEqualSlices(f32, &.{7}, weights.row(0).?.f32);
        }
        try std.testing.expectError(error.InvalidColumnType, batch.typedColumn(i32, 1));
    }
    try std.testing.expect((try parser.next()) == null);
}

test "ASCII zero-property records consume empty lines and skip zero-count elements" {
    const data = "ply\nformat ascii 1.0\nelement ignored 0\nproperty int value\n" ++
        "element blank 3\nelement last 1\nproperty uchar flag\nend_header\n" ++
        "\n\n\n123\n";
    var reader: std.Io.Reader = .fixed(data);
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 8 });
    defer parser.deinit();
    var blank = (try parser.next()).?;
    try std.testing.expectEqual(@as(usize, 1), blank.info().element_index);
    try std.testing.expectEqual(@as(usize, 0), blank.columnCount());
    try std.testing.expectEqual(@as(usize, 3), blank.info().record_count);
    blank.release();
    var last = (try parser.next()).?;
    try std.testing.expectEqual(@as(u8, 123), (try last.typedColumn(u8, 0))[0]);
    try std.testing.expectEqual(@as(u64, 1), last.info().sequence);
    last.release();
    try std.testing.expect((try parser.next()) == null);
}

test "CRLF and fragmented record semantics with strict missing/extra tokens" {
    const h = "ply\nformat ascii 1.0\nelement p 2\nproperty float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "  1.25\r\n\t2.5\r\n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 128 });
    defer parser.deinit();
    var batch = (try parser.next()).?;
    try std.testing.expectEqualSlices(f32, &.{ 1.25, 2.5 }, try batch.typedColumn(f32, 0));
    batch.release();
    try std.testing.expect((try parser.next()) == null);
}

test "malformed ASCII line is terminal and never publishes partial batch" {
    const h = "ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "1 2\n3 bad\n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 64 });
    defer parser.deinit();
    // header() is only valid before a terminal parsing failure.
    const body_offset = parser.header().body_offset;
    try std.testing.expectError(error.InvalidNumber, parser.next());
    try std.testing.expectEqual(z.Parser.State.failed, parser.state);
    const diagnostic = parser.asciiDiagnostic().?;
    try std.testing.expectEqual(@as(u64, 1), diagnostic.record_index.?);
    try std.testing.expectEqual(@as(u64, 1), diagnostic.property_index.?);
    // First line is "1 2\n" (4 bytes), and "bad" starts two bytes
    // into the second record. Record-start and token-start are distinct.
    try std.testing.expectEqual(body_offset + 4, diagnostic.byte_offset.?);
    try std.testing.expectEqual(body_offset + 6, diagnostic.token_byte_offset.?);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

test "ASCII malformed list counts and input truncation" {
    const h = "ply\nformat ascii 1.0\nelement face 1\nproperty list char int ids\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "-1\n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    try std.testing.expectError(error.NegativeListCount, parser.next());
    parser.deinit();

    reader = .fixed(h ++ "3 1 2\n");
    parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    try std.testing.expectError(error.MissingValue, parser.next());
    parser.deinit();

    reader = .fixed(h ++ "3 1 2 3");
    parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    try std.testing.expectError(error.TruncatedAsciiBody, parser.next());
    try std.testing.expectEqual(z.Diagnostic.Category.truncation, parser.asciiDiagnostic().?.category);
    parser.deinit();
}

test "ASCII record and token limits reject oversized input before unbounded allocation" {
    const h = "ply\nformat ascii 1.0\nelement p 1\nproperty double x\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "123456789\n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .limits = .{ .max_ascii_record_bytes = 8, .max_ascii_token_bytes = 8 },
    });
    try std.testing.expectError(error.RecordTooLarge, parser.next());
    parser.deinit();

    reader = .fixed(h ++ "123456789\n");
    parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .limits = .{ .max_ascii_record_bytes = 64, .max_ascii_token_bytes = 8 },
    });
    try std.testing.expectError(error.TokenTooLong, parser.next());
    try std.testing.expectEqual(z.Diagnostic.Category.resource_limit, parser.asciiDiagnostic().?.category);
    parser.deinit();
}

test "ASCII streaming reuses buffers without collecting whole file" {
    const h = "ply\nformat ascii 1.0\nelement p 100000\nproperty float x\nend_header\n";
    const line = "1.5\n";
    const source = try std.testing.allocator.alloc(u8, h.len + 100000 * line.len);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..h.len], h);
    for (0..100000) |i| @memcpy(source[h.len + i * line.len ..][0..line.len], line);
    var reader: std.Io.Reader = .fixed(source);
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 16 * 1024,
        .memory_budget = 1024 * 1024,
    });
    defer parser.deinit();
    var count: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        count += batch.info().record_count;
        batch.release();
    }
    try std.testing.expectEqual(@as(usize, 100000), count);
    try std.testing.expect(parser.memoryStats().peak_total_bytes <= 1024 * 1024);
}

test "ASCII list memory pressure retains staged record until a lease is released" {
    const allocator = std.testing.allocator;
    const h = "ply\nformat ascii 1.0\nelement face 2\nproperty list ushort int ids\nend_header\n";
    var fixture: std.ArrayList(u8) = .empty;
    defer fixture.deinit(allocator);
    try fixture.appendSlice(allocator, h);
    for (0..2) |_| {
        try fixture.appendSlice(allocator, "1000");
        for (0..1000) |_| try fixture.appendSlice(allocator, " 1");
        try fixture.append(allocator, '\n');
    }

    // Determine a budget strictly between one and two live list batches
    // rather than relying on allocator-dependent bookkeeping sizes.
    var probe_reader: std.Io.Reader = .fixed(fixture.items);
    var probe = try z.Parser.init(allocator, std.testing.io, &probe_reader, .{ .memory_budget = 1024 * 1024, .chunk_size = 1024 });
    var first = (try probe.next()).?;
    const one_live = probe.memoryStats().live_bytes;
    var second = (try probe.next()).?;
    const two_live = probe.memoryStats().live_bytes;
    try std.testing.expect(two_live > one_live + 2);
    first.release();
    second.release();
    probe.deinit();
    const limit = one_live + (two_live - one_live) / 2;

    var reader: std.Io.Reader = .fixed(fixture.items);
    var parser = try z.Parser.init(allocator, std.testing.io, &reader, .{ .memory_budget = limit, .chunk_size = 1024 });
    defer parser.deinit();
    var a = (try parser.next()).?;
    try std.testing.expectEqual(@as(usize, 1000), (try a.listColumn(0)).row(0).?.i32.len);
    try std.testing.expectError(error.MemoryPressure, parser.next());
    a.release();
    var b = (try parser.next()).?;
    try std.testing.expectEqual(@as(u64, 1), b.info().first_record);
    try std.testing.expectEqual(@as(usize, 1000), (try b.listColumn(0)).row(0).?.i32.len);
    b.release();
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expect(parser.memoryStats().peak_total_bytes <= limit);
}

test "ASCII reused list buffers can grow within the final memory budget" {
    // Both records have the same serialized line size, so the scratch
    // allocation is unchanged. The second record needs a larger value
    // column; the reusable first record's buffer is no longer leased.
    const allocator = std.testing.allocator;
    const h = "ply\nformat ascii 1.0\nelement face 2\nproperty list ushort int ids\nend_header\n";
    var fixture: std.ArrayList(u8) = .empty;
    defer fixture.deinit(allocator);
    try fixture.appendSlice(allocator, h);
    try fixture.appendSlice(allocator, "800");
    for (0..800) |_| try fixture.appendSlice(allocator, " 1");
    for (0..401) |_| try fixture.append(allocator, ' ');
    try fixture.append(allocator, '\n');
    try fixture.appendSlice(allocator, "1000");
    for (0..1000) |_| try fixture.appendSlice(allocator, " 2");
    try fixture.append(allocator, '\n');

    var probe_reader: std.Io.Reader = .fixed(fixture.items);
    var probe = try z.Parser.init(allocator, std.testing.io, &probe_reader, .{ .memory_budget = 1024 * 1024, .chunk_size = 1024 });
    var first = (try probe.next()).?;
    const first_live = probe.memoryStats().live_bytes;
    first.release();
    var second = (try probe.next()).?;
    const second_live = probe.memoryStats().live_bytes;
    second.release();
    probe.deinit();

    // Enough for either complete batch, but not for two full list-value
    // allocations retained simultaneously during the larger replacement.
    const limit = @max(first_live, second_live) + 128;
    var reader: std.Io.Reader = .fixed(fixture.items);
    var parser = try z.Parser.init(allocator, std.testing.io, &reader, .{ .memory_budget = limit, .chunk_size = 1024 });
    defer parser.deinit();
    var a = (try parser.next()).?;
    try std.testing.expectEqual(@as(usize, 800), (try a.listColumn(0)).row(0).?.i32.len);
    a.release();
    var b = (try parser.next()).?;
    defer b.release();
    const items = (try b.listColumn(0)).row(0).?.i32;
    try std.testing.expectEqual(@as(usize, 1000), items.len);
    try std.testing.expectEqual(@as(i32, 2), items[999]);
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expect(parser.memoryStats().peak_total_bytes <= limit);
}

test "ASCII lists reject the configured count limit before item allocation" {
    const h = "ply\nformat ascii 1.0\nelement face 1\nproperty list uint int ids\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "4 1 2 3 4\n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .limits = .{ .max_list_items_per_record = 3 },
    });
    try std.testing.expectError(error.ListTooLarge, parser.next());
    parser.deinit();

    reader = .fixed(h ++ "4294967295\n");
    parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .limits = .{ .max_list_items_per_record = 100 },
    });
    try std.testing.expectError(error.ListTooLarge, parser.next());
    parser.deinit();
}

test "ASCII list allocation failure leaves no published partial batch or leaked allocations" {
    const source = "ply\nformat ascii 1.0\nelement face 1\n" ++
        "property float confidence\nproperty list uchar int indices\n" ++
        "property list uchar double weights\nend_header\n" ++
        "0.5 3 10 11 12 2 0.125 0.875\n";
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..80) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reader: std.Io.Reader = .fixed(source);
        if (z.Parser.init(failing.allocator(), std.testing.io, &reader, .{ .memory_budget = 1024 * 1024, .chunk_size = 1024 })) |value| {
            var parser = value;
            defer parser.deinit();
            if (parser.next()) |maybe_batch| {
                var batch = maybe_batch orelse return error.TestUnexpectedResult;
                defer batch.release();
                try std.testing.expectEqual(@as(usize, 3), (try batch.listColumn(1)).row(0).?.i32.len);
                try std.testing.expectEqual(@as(usize, 2), (try batch.listColumn(2)).row(0).?.f64.len);
                successes += 1;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
            }
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
    }
    try std.testing.expect(failures > 0);
    try std.testing.expect(successes > 0);
}

test "ASCII large list record exceeds preferred chunk size but remains budgeted" {
    const allocator = std.testing.allocator;
    const h = "ply\nformat ascii 1.0\nelement face 1\nproperty list uint int ids\nend_header\n";
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, h ++ "12000");
    for (0..12000) |_| try source.appendSlice(allocator, " 7");
    try source.append(allocator, '\n');

    var reader: std.Io.Reader = .fixed(source.items);
    var parser = try z.Parser.init(allocator, std.testing.io, &reader, .{
        .chunk_size = 128,
        .memory_budget = 512 * 1024,
        .limits = .{
            .max_ascii_record_bytes = 64 * 1024,
            .max_list_items_per_record = 12000,
        },
    });
    defer parser.deinit();
    var batch = (try parser.next()).?;
    const values = (try batch.listColumn(0)).row(0).?.i32;
    try std.testing.expectEqual(@as(usize, 12000), values.len);
    try std.testing.expectEqual(@as(i32, 7), values[0]);
    try std.testing.expectEqual(@as(i32, 7), values[values.len - 1]);
    batch.release();
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expect(parser.memoryStats().peak_total_bytes <= 512 * 1024);
}

test "ASCII diagnostics point to invalid list item and extra token" {
    const h = "ply\nformat ascii 1.0\nelement face 1\nproperty list uchar int ids\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "3 1 nope 3\n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    const body_offset = parser.header().body_offset;
    try std.testing.expectError(error.InvalidNumber, parser.next());
    const bad_item = parser.asciiDiagnostic().?;
    try std.testing.expectEqual(@as(u64, 0), bad_item.property_index.?);
    try std.testing.expectEqual(body_offset, bad_item.byte_offset.?);
    try std.testing.expectEqual(body_offset + 4, bad_item.token_byte_offset.?);
    parser.deinit();

    reader = .fixed(h ++ "2 1 2 99\n");
    parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    const extra_body_offset = parser.header().body_offset;
    try std.testing.expectError(error.UnexpectedValue, parser.next());
    const extra = parser.asciiDiagnostic().?;
    try std.testing.expect(extra.property_index == null);
    try std.testing.expectEqual(extra_body_offset + 6, extra.token_byte_offset.?);
    parser.deinit();
}

test "ASCII diagnostics identify a missing token at record end" {
    const h = "ply\nformat ascii 1.0\nelement vertex 1\nproperty int x\nproperty int y\nend_header\n";
    var reader: std.Io.Reader = .fixed(h ++ "12 \n");
    var parser = try z.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    const body_offset = parser.header().body_offset;
    try std.testing.expectError(error.MissingValue, parser.next());
    const missing = parser.asciiDiagnostic().?;
    try std.testing.expectEqual(@as(u64, 1), missing.property_index.?);
    try std.testing.expectEqual(body_offset + 3, missing.token_byte_offset.?);
}

test "ListColumn.row rejects an empty offset table and overflowing indices" {
    const empty = z.ListColumn{
        .offsets = &.{},
        .values = .{ .u8 = &.{} },
    };
    try std.testing.expect(empty.row(0) == null);
    try std.testing.expect(empty.row(std.math.maxInt(usize)) == null);
    const single = z.ListColumn{
        .offsets = &.{ 0, 2 },
        .values = .{ .u8 = &.{ 7, 8 } },
    };
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, single.row(0).?.u8);
    try std.testing.expect(single.row(std.math.maxInt(usize)) == null);
}
