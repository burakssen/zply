//! Phase 11 M8: bounded fuzzing at the header, numeric, and whole-parser
//! boundaries, plus an independent valid-document generator.
//!
//! Intentionally uses ONLY the zply_internals module. Importing zply as well
//! would assign shared source files to two modules in Zig 0.17.1.
//! Each std.testing.fuzz call replays a small inline corpus in regular tests;
//! prolonged coverage-guided campaigns use `zig build fuzz-phase11 --fuzz=N`.
const std = @import("std");
const internal = @import("zply_internals");
const number = internal.ascii.number;
const Encoding = internal.types.Encoding;
const Parser = internal.parser.Parser;

const Record = struct {
    id: u8,
    count: usize,
    items: [4]i16,
    score: i16,
};

/// Small independent serializer. It does not call any production PLY
/// tokenizer, record scanner, layout compiler, or decoding function.
const Document = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    body_start: usize = 0,
    body_len: usize = 0,
    records: [8]Record = undefined,
    record_count: usize = 0,
    encoding: Encoding,

    fn append(self: *Document, data: []const u8) void {
        std.debug.assert(self.len + data.len <= self.bytes.len);
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn print(self: *Document, comptime fmt: []const u8, args: anytype) !void {
        const slice = try std.fmt.bufPrint(self.bytes[self.len..], fmt, args);
        self.len += slice.len;
    }

    fn integer(self: *Document, comptime T: type, value: T, endian: std.builtin.Endian) void {
        var raw: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, endian);
        self.append(&raw);
    }

    fn generate(seed: u64, encoding: Encoding) !Document {
        var doc: Document = .{ .encoding = encoding };
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        doc.record_count = random.intRangeAtMost(usize, 1, 8);
        for (0..doc.record_count) |i| {
            var rec: Record = .{
                .id = random.int(u8),
                .count = random.intRangeAtMost(usize, 0, 4),
                .items = .{ 0, 0, 0, 0 },
                .score = random.intRangeAtMost(i16, -1000, 1000),
            };
            for (0..rec.count) |j| rec.items[j] = random.int(i16);
            doc.records[i] = rec;
        }

        doc.append("ply\n");
        switch (encoding) {
            .ascii => doc.append("format ascii 1.0\n"),
            .binary_little_endian => doc.append("format binary_little_endian 1.0\n"),
            .binary_big_endian => doc.append("format binary_big_endian 1.0\n"),
        }
        try doc.print("element sample {d}\n", .{doc.record_count});
        doc.append("property uchar id\n" ++
            "property list uchar short values\n" ++
            "property float score\nend_header\n");
        doc.body_start = doc.len;
        for (doc.records[0..doc.record_count]) |rec| {
            if (encoding == .ascii) {
                try doc.print("{d} {d}", .{ rec.id, rec.count });
                for (rec.items[0..rec.count]) |item| try doc.print(" {d}", .{item});
                try doc.print(" {d}\n", .{rec.score});
            } else {
                const endian: std.builtin.Endian = if (encoding == .binary_little_endian) .little else .big;
                doc.integer(u8, rec.id, endian);
                doc.integer(u8, @intCast(rec.count), endian);
                for (rec.items[0..rec.count]) |item| doc.integer(i16, item, endian);
                const score: f32 = @floatFromInt(rec.score);
                doc.integer(u32, @bitCast(score), endian);
            }
        }
        doc.body_len = doc.len - doc.body_start;
        doc.append("TAIL"); // Completion must not consume logical trailing bytes.
        return doc;
    }
};

fn assertBudget(parser: *const Parser) !void {
    const stats = parser.memoryStats();
    try std.testing.expect(stats.live_bytes <= stats.budget_bytes);
    try std.testing.expect(stats.reserved_bytes <= stats.budget_bytes - stats.live_bytes);
    try std.testing.expect(stats.peak_total_bytes <= stats.budget_bytes);
}

fn verifyValidDocument(doc: *const Document, chunk_size: usize) !void {
    var reader: std.Io.Reader = .fixed(doc.bytes[0..doc.len]);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = chunk_size,
        .memory_budget = 1024 * 1024,
    });
    defer parser.deinit();
    try std.testing.expectEqual(doc.record_count, @as(usize, @intCast(parser.header().elements[0].count)));

    var seen: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(u64, @intCast(seen)), info.first_record);
        try std.testing.expect(info.record_count > 0);
        const ids = try batch.typedColumn(u8, 0);
        const lists = try batch.listColumn(1);
        const scores = try batch.typedColumn(f32, 2);
        try std.testing.expectEqual(info.record_count, ids.len);
        try std.testing.expectEqual(info.record_count, scores.len);
        try std.testing.expectEqual(info.record_count + 1, lists.offsets.len);
        try std.testing.expectEqual(@as(usize, 0), lists.offsets[0]);
        try std.testing.expectEqual(lists.values.len(), lists.offsets[info.record_count]);
        for (0..info.record_count) |j| {
            const expected = doc.records[seen + j];
            try std.testing.expectEqual(expected.id, ids[j]);
            const row = (lists.row(j) orelse return error.InvalidGeneratedList).i16;
            try std.testing.expectEqualSlices(i16, expected.items[0..expected.count], row);
            const score: f32 = @floatFromInt(expected.score);
            try std.testing.expectEqual(@as(u32, @bitCast(score)), @as(u32, @bitCast(scores[j])));
        }
        seen += info.record_count;
        try std.testing.expect(seen <= doc.record_count);
        try assertBudget(&parser);
    }
    try std.testing.expectEqual(doc.record_count, seen);
    try assertBudget(&parser);
    try std.testing.expectEqual(@as(u8, 'T'), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 'A'), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 'I'), try reader.takeByte());
    try std.testing.expectEqual(@as(u8, 'L'), try reader.takeByte());
}

fn fuzzValid(_: void, smith: *std.testing.Smith) !void {
    const seed = smith.value(u64);
    const enc: Encoding = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .ascii,
        1 => .binary_little_endian,
        else => .binary_big_endian,
    };
    const chunk_size: usize = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => 64,
        1 => 128,
        else => 512,
    };
    const doc = try Document.generate(seed, enc);
    try verifyValidDocument(&doc, chunk_size);
}

test "M8 deterministic independent serializer roundtrips three encodings and chunk boundaries" {
    inline for (.{ .ascii, .binary_little_endian, .binary_big_endian }) |enc| {
        for (0..12) |seed| {
            const doc = try Document.generate(@as(u64, @intCast(seed)) *% 0x9e3779b97f4a7c15, enc);
            try verifyValidDocument(&doc, 64);
            try verifyValidDocument(&doc, 512);
        }
    }
}

test "M8 fuzz valid generated ASCII and both binary encodings" {
    try std.testing.fuzz({}, fuzzValid, .{
        .corpus = &.{ "", "\x00", "\x01\x02\x03", "\xff\xff\xff\xff\xff\xff\xff\xff", "\x50\x4c\x59" },
    });
}

test "M8 checked-in regression corpus includes all encodings and an invalid schema" {
    const valid = [_][]const u8{
        @embedFile("corpus/valid_ascii.ply"),
        @embedFile("corpus/valid_binary_le.ply"),
        @embedFile("corpus/valid_binary_be.ply"),
    };
    for (valid) |source| {
        var reader: std.Io.Reader = .fixed(source);
        var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 64 });
        defer parser.deinit();
        var seen: usize = 0;
        while (try parser.next()) |value| {
            var batch = value;
            defer batch.release();
            const ids = try batch.typedColumn(u8, 0);
            const lists = try batch.listColumn(1);
            const scores = try batch.typedColumn(f32, 2);
            for (0..ids.len) |j| {
                const ordinal = seen + j;
                try std.testing.expect(ordinal < 2);
                try std.testing.expectEqual(@as(u8, if (ordinal == 0) 7 else 8), ids[j]);
                if (ordinal == 0) {
                    try std.testing.expectEqualSlices(i16, &.{ 10, -10 }, lists.row(j).?.i16);
                    try std.testing.expectEqual(@as(f32, 1), scores[j]);
                } else {
                    try std.testing.expectEqual(@as(usize, 0), lists.row(j).?.i16.len);
                    try std.testing.expectEqual(@as(f32, -2), scores[j]);
                }
            }
            seen += ids.len;
        }
        try std.testing.expectEqual(@as(usize, 2), seen);
    }
    var invalid_reader: std.Io.Reader = .fixed(@embedFile("corpus/invalid_list_type.ply"));
    try std.testing.expectError(error.InvalidListCountType,
        Parser.init(std.testing.allocator, std.testing.io, &invalid_reader, .{}));
}

fn fuzzHeader(_: void, smith: *std.testing.Smith) !void {
    var source: [512]u8 = undefined;
    const length: usize = smith.valueRangeAtMost(u16, 0, 256);
    smith.bytes(source[0..length]);
    var reader: std.Io.Reader = .fixed(source[0..length]);
    var diagnostic: internal.errors.Diagnostic = .{ .category = .header };
    var storage = internal.header_parser.parseHeaderDetailed(std.testing.allocator, &reader, .{
        .limits = .{ .max_header_bytes = 512, .max_header_line_bytes = 256 },
    }, &diagnostic) catch |err| {
        try std.testing.expectEqual(@as(anyerror, err), diagnostic.code.?);
        return; // Malformed input is expected; a panic, leak, or bad diagnostic is not.
    };
    defer storage.deinit();
    try std.testing.expectEqual(@as(u16, 1), storage.header.version.major);
    try std.testing.expectEqual(@as(u16, 0), storage.header.version.minor);
    try std.testing.expect(storage.header.body_offset <= length);
    try std.testing.expectEqual(storage.header.elements.len, storage.layouts.len);
}

test "M8 fuzz arbitrary bounded PLY headers with stable error diagnostics" {
    try std.testing.fuzz({}, fuzzHeader, .{
        .corpus = &.{ "", "ply", "ply\nformat ascii 1.0\nend_header\n", "ply\nformat binary_big_endian 1.0\nelement a 0\nend_header\n", "ply\nproperty float x\n", "\xff\x00\xff" },
    });
}

const IntegerOracle = union(enum) { valid: i16, invalid, overflow };

/// Does not call the production numeric lexer. The Zig standard library is
/// only used for conversion after independently checking decimal grammar.
fn oracleInteger(token: []const u8) IntegerOracle {
    if (token.len == 0) return .invalid;
    var start: usize = 0;
    if (token[0] == '+' or token[0] == '-') start = 1;
    if (start == token.len) return .invalid;
    for (token[start..]) |byte| {
        if (byte < '0' or byte > '9') return .invalid;
    }
    const wide = std.fmt.parseInt(i64, token, 10) catch return .overflow;
    if (wide < std.math.minInt(i16) or wide > std.math.maxInt(i16)) return .overflow;
    return .{ .valid = @intCast(wide) };
}

fn fuzzNumber(_: void, smith: *std.testing.Smith) !void {
    var token: [96]u8 = undefined;
    const length: usize = smith.valueRangeAtMost(u8, 0, 96);
    smith.bytes(token[0..length]);
    switch (oracleInteger(token[0..length])) {
        .valid => |expected| try std.testing.expectEqual(expected, try number.parse(i16, token[0..length])),
        .invalid => try std.testing.expectError(error.InvalidNumber, number.parse(i16, token[0..length])),
        .overflow => try std.testing.expectError(error.IntegerOverflow, number.parse(i16, token[0..length])),
    }
    // Float parsing is a separate lexer: random bytes may be rejected or
    // decoded, but accepted values must not silently overflow to infinity.
    const parsed = number.parse(f32, token[0..length]) catch |err| switch (err) {
        error.InvalidNumber, error.FloatOverflow => return,
        else => return err,
    };
    if (std.math.isInf(parsed)) {
        try std.testing.expect(std.mem.eql(u8, token[0..length], "inf") or
            std.mem.eql(u8, token[0..length], "+inf") or
            std.mem.eql(u8, token[0..length], "-inf"));
    }
}

test "M8 fuzz ASCII numeric lexical boundaries against an independent integer oracle" {
    try std.testing.fuzz({}, fuzzNumber, .{
        .corpus = &.{ "", "+", "-32768", "32767", "32768", "-32769", "12.0", "1e999", "-0", "nan", "inf", "\x00\xff" },
    });
}

/// Only the body is mutated: header failure and invalid initialization do
/// not mask deeper binary list, ASCII token, and streaming state behavior.
fn fuzzMutated(_: void, smith: *std.testing.Smith) !void {
    const seed = smith.value(u64);
    const enc: Encoding = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .ascii,
        1 => .binary_little_endian,
        else => .binary_big_endian,
    };
    var doc = try Document.generate(seed, enc);
    const mode = smith.valueRangeAtMost(u8, 0, 4);
    switch (mode) {
        0 => {}, // Valid control case.
        1 => { // Truncate at any byte position within the body.
            const body_offset: usize = smith.valueRangeAtMost(u16, 0, @intCast(doc.body_len - 1));
            doc.len = doc.body_start + body_offset;
        },
        2 => { // Corrupt one body byte, possibly inside a count or scalar.
            const body_offset: usize = smith.valueRangeAtMost(u16, 0, @intCast(doc.body_len - 1));
            doc.bytes[doc.body_start + body_offset] = smith.value(u8);
        },
        3 => { // Set first list count to maximum (ASCII uses a lexical fault).
            if (enc == .ascii) {
                doc.bytes[doc.body_start] = '@';
            } else {
                doc.bytes[doc.body_start + 1] = 255;
            }
        },
        else => doc.len = doc.body_start, // Header-only, declared body missing.
    }
    var reader: std.Io.Reader = .fixed(doc.bytes[0..doc.len]);
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 128,
        .memory_budget = 1024 * 1024,
        .limits = .{ .max_list_items_per_record = 64 },
    });
    defer parser.deinit();
    var seen: usize = 0;
    while (true) {
        const maybe_batch = parser.next() catch |err| {
            const reported = parser.lastDiagnostic() orelse return error.MissingFuzzDiagnostic;
            try std.testing.expectEqual(@as(anyerror, err), reported.code.?);
            const generic: anyerror = err;
            switch (generic) {
                error.InvalidNumber, error.IntegerOverflow, error.FloatOverflow,
                error.MissingValue, error.UnexpectedValue, error.NegativeListCount,
                error.ListTooLarge, error.RecordTooLarge, error.TokenTooLong,
                error.InvalidAsciiRecord, error.InvalidLineEnding,
                error.TruncatedBody, error.TruncatedRecord, error.TruncatedListCount,
                error.TruncatedListPayload, error.TruncatedAsciiBody, error.InvalidListCount,
                => return,
                else => return error.UnexpectedMutatedParserFailure,
            }
        };
        var batch = maybe_batch orelse break;
        defer batch.release();
        const info = batch.info();
        try std.testing.expect(info.record_count > 0);
        try std.testing.expectEqual(@as(u64, @intCast(seen)), info.first_record);
        const list = try batch.listColumn(1);
        try std.testing.expectEqual(info.record_count + 1, list.offsets.len);
        try std.testing.expectEqual(@as(usize, 0), list.offsets[0]);
        try std.testing.expectEqual(list.values.len(), list.offsets[info.record_count]);
        for (0..info.record_count) |j| {
            try std.testing.expect(list.offsets[j] <= list.offsets[j + 1]);
            try std.testing.expect(list.row(j) != null);
        }
        seen += info.record_count;
        try std.testing.expect(seen <= doc.record_count);
        try assertBudget(&parser);
    }
    try std.testing.expectEqual(doc.record_count, seen);
}

test "M8 fuzz targeted ASCII and binary body mutations without publishing invalid batches" {
    try std.testing.fuzz({}, fuzzMutated, .{
        .corpus = &.{ "", "\x01", "\x02\x02\x02", "\x03\xff", "\xff\xff\xff\xff\xff\xff\xff\xff" },
    });
}
