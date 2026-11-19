//! Phase 11 M7: resource-limit terminality, declared-body EOF, and budget
//! invariants through the public Parser API.
const std = @import("std");
const ply = @import("zply");
const FailingReader = @import("failing_reader.zig").FailingReader;

const Case = struct { header: []const u8, body: []const u8 };

const cases = [_]Case{
    .{
        .header = "ply\nformat ascii 1.0\nelement item 1\nproperty uchar x\nend_header\n",
        .body = "12\n",
    },
    .{
        .header = "ply\nformat binary_little_endian 1.0\nelement item 1\nproperty uchar x\nend_header\n",
        .body = "\x0c",
    },
    .{
        .header = "ply\nformat binary_little_endian 1.0\nelement face 1\nproperty list ushort int indices\nend_header\n",
        .body = "\x01\x00\x0c\x00\x00\x00",
    },
    .{
        .header = "ply\nformat binary_big_endian 1.0\nelement face 1\nproperty list ushort int indices\nend_header\n",
        .body = "\x00\x01\x00\x00\x00\x0c",
    },
};

test "M7 all encodings stop at declared record count and leave trailing bytes unread" {
    for (cases) |case| {
        const full = try std.testing.allocator.alloc(u8, case.header.len + case.body.len + 4);
        defer std.testing.allocator.free(full);
        @memcpy(full[0..case.header.len], case.header);
        @memcpy(full[case.header.len..][0..case.body.len], case.body);
        @memcpy(full[case.header.len + case.body.len ..], "TAIL");
        var reader: std.Io.Reader = .fixed(full);
        var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 64 });
        defer parser.deinit();
        var batch = (try parser.next()) orelse return error.UnexpectedEndOfInput;
        try std.testing.expectEqual(@as(usize, 1), batch.info().record_count);
        batch.release();
        try std.testing.expect((try parser.next()) == null);
        try std.testing.expectEqual(ply.Parser.State.completed, parser.state);
        try std.testing.expect((try parser.next()) == null);
        try std.testing.expectEqual(@as(u8, 'T'), try reader.takeByte());
        try std.testing.expectEqual(@as(u8, 'A'), try reader.takeByte());
        try std.testing.expectEqual(@as(u8, 'I'), try reader.takeByte());
        try std.testing.expectEqual(@as(u8, 'L'), try reader.takeByte());
    }
}

test "M7 empty declared body requires no physical EOF or speculative read" {
    const header = "ply\nformat binary_little_endian 1.0\nelement empty 0\nproperty float x\nend_header\n";
    var reader: std.Io.Reader = .fixed(header ++ "NEXT");
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expectEqual(ply.Parser.State.completed, parser.state);
    try std.testing.expectEqual(@as(u8, 'N'), try reader.takeByte());
}

test "M7 irrecoverable fixed-width record limit fails once without advancing input" {
    const header = "ply\nformat binary_little_endian 1.0\nelement item 1\nproperty double x\nproperty double y\nend_header\n";
    var reader: std.Io.Reader = .fixed(header ++ "PAYLOAD");
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 8,
        .limits = .{ .max_record_bytes = 8 },
    });
    defer parser.deinit();
    const before = reader.seek;
    try std.testing.expectError(error.RecordTooLarge, parser.next());
    try std.testing.expectEqual(before, reader.seek);
    try std.testing.expectEqual(ply.Parser.State.failed, parser.state);
    try std.testing.expectEqual(ply.Diagnostic.Category.resource_limit, parser.lastDiagnostic().?.category);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

test "M7 binary admission cannot retry indefinitely when minimum budget is impossible" {
    const header = "ply\nformat binary_little_endian 1.0\nelement item 1\nproperty uchar x\nend_header\n";
    const fixture = header ++ "\x0cTAIL";
    // Determine the exact parser bootstrap/header cost without depending on
    // allocator implementation details or std.Io internals.
    var probe_reader: std.Io.Reader = .fixed(fixture);
    var probe = try ply.Parser.init(std.testing.allocator, std.testing.io, &probe_reader, .{
        .chunk_size = 1,
        .memory_budget = 1024 * 1024,
    });
    // Header parsing can temporarily allocate scratch memory that is freed
    // before init returns. A budget based only on live_bytes can therefore
    // fail inside init rather than testing body admission as intended.
    const init_peak = probe.memoryStats().peak_total_bytes;
    probe.deinit();

    var reader: std.Io.Reader = .fixed(fixture);
    // Reproduce the header's peak but leave too little headroom to create
    // the binary output/task infrastructure. This must fail on next(),
    // without consuming a body byte or entering a retry loop.
    const cap = init_peak + 32;
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 1,
        .memory_budget = cap,
    });
    defer parser.deinit();
    const before = reader.seek;
    try std.testing.expectError(error.ResourceLimitExceeded, parser.next());
    try std.testing.expectEqual(before, reader.seek);
    try std.testing.expectEqual(ply.Parser.State.failed, parser.state);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
    const stats = parser.memoryStats();
    try std.testing.expect(stats.peak_total_bytes <= cap);
    try std.testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
}

test "M7 truncated fixed body and underlying reader failure remain distinct" {
    const header = "ply\nformat binary_little_endian 1.0\nelement item 1\nproperty uint x\nend_header\n";
    {
        var reader: std.Io.Reader = .fixed(header ++ "\x01\x02");
        var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 8 });
        defer parser.deinit();
        try std.testing.expectError(error.TruncatedBody, parser.next());
        try std.testing.expectEqual(ply.Diagnostic.Category.truncation, parser.lastDiagnostic().?.category);
        try std.testing.expectEqual(ply.Parser.State.failed, parser.state);
    }
    {
        var failing = FailingReader.init(header ++ "\x01\x02\x03\x04", header.len + 2);
        var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, failing.reader(), .{ .chunk_size = 8 });
        defer parser.deinit();
        try std.testing.expectError(error.ReadFailed, parser.next());
        try std.testing.expectEqual(ply.Diagnostic.Category.reader, parser.lastDiagnostic().?.category);
        try std.testing.expectEqual(ply.Parser.State.failed, parser.state);
    }
}

test "M7 fixed-width streaming respects configured budgets with full release" {
    const header = "ply\nformat binary_little_endian 1.0\nelement item 256\nproperty uchar x\nend_header\n";
    const body: [256]u8 = @splat(42);
    inline for (.{ 16 * 1024, 64 * 1024, 1024 * 1024 }) |budget| {
        var reader: std.Io.Reader = .fixed(header ++ body);
        var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
            .chunk_size = 64,
            .memory_budget = budget,
        });
        defer parser.deinit();
        var seen: usize = 0;
        while (try parser.next()) |value| {
            var batch = value;
            defer batch.release();
            for (try batch.typedColumn(u8, 0)) |item| try std.testing.expectEqual(@as(u8, 42), item);
            seen += batch.info().record_count;
            const stats = parser.memoryStats();
            try std.testing.expect(stats.live_bytes <= budget);
            try std.testing.expect(stats.reserved_bytes <= budget - stats.live_bytes);
            try std.testing.expect(stats.peak_total_bytes <= budget);
        }
        try std.testing.expectEqual(@as(usize, 256), seen);
        try std.testing.expectEqual(@as(usize, 0), parser.memoryStats().reserved_bytes);
    }
}
