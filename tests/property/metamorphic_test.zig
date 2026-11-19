//! Phase 11 M11: changes to reader fragmentation, chunking, budgets, delivery
//! order, executor, encoding, or irrelevant metadata cannot change records.
//! Expectations come from M9's independently constructed logical cells.
const std = @import("std");
const internal = @import("zply_internals");
const support = @import("streaming_support");
const generator = @import("document_generator.zig");
const Parser = internal.parser.Parser;
const Batch = internal.parser.Batch;
const Document = generator.Document;
const Encoding = generator.Encoding;

const ReaderKind = enum { fixed, one_byte, primes, irregular };

fn rawBits(value: anytype) u64 {
    const U = switch (@bitSizeOf(@TypeOf(value))) {
        8 => u8,
        16 => u16,
        32 => u32,
        64 => u64,
        else => @compileError("unexpected PLY scalar width"),
    };
    return @as(u64, @as(U, @bitCast(value)));
}

fn checkTyped(expected: generator.Scalar, actual: anytype, bits: []const u64) !void {
    switch (actual) {
        inline else => |values, tag| {
            try std.testing.expectEqualStrings(@tagName(expected), @tagName(tag));
            try std.testing.expectEqual(bits.len, values.len);
            for (values, bits) |value, expected_bits|
                try std.testing.expectEqual(expected_bits, rawBits(value));
        },
    }
}

fn checkBatch(doc: *const Document, batch: *const Batch) !void {
    const info = batch.info();
    try std.testing.expect(info.element_index < doc.element_count);
    try std.testing.expect(info.record_count > 0);
    const element = doc.elements[info.element_index];
    const start: usize = @intCast(info.first_record);
    try std.testing.expect(start <= element.count);
    try std.testing.expect(info.record_count <= element.count - start);
    try std.testing.expectEqual(element.property_count, batch.columnCount());

    for (element.properties[0..element.property_count], 0..) |property, p| {
        if (property.is_list) {
            const list = try batch.listColumn(p);
            try std.testing.expectEqual(info.record_count + 1, list.offsets.len);
            try std.testing.expectEqual(@as(usize, 0), list.offsets[0]);
            var total: usize = 0;
            for (0..info.record_count) |r| {
                const cell = doc.cells[info.element_index][start + r][p];
                try std.testing.expectEqual(total, list.offsets[r]);
                total += cell.len;
                try std.testing.expectEqual(total, list.offsets[r + 1]);
                try checkTyped(property.ty, list.row(r) orelse return error.MissingListRow, cell.bits[0..cell.len]);
            }
            try std.testing.expectEqual(total, list.values.len());
        } else {
            const column = batch.columnByPropertyIndex(p) orelse return error.MissingScalarColumn;
            try std.testing.expect(column.list == null);
            switch (column.values) {
                inline else => |values, tag| {
                    try std.testing.expectEqualStrings(@tagName(property.ty), @tagName(tag));
                    try std.testing.expectEqual(info.record_count, values.len);
                    for (values, 0..) |value, r| {
                        const cell = doc.cells[info.element_index][start + r][p];
                        try std.testing.expectEqual(@as(usize, 1), cell.len);
                        try std.testing.expectEqual(cell.bits[0], rawBits(value));
                    }
                },
            }
        }
    }
}

const Tracker = struct {
    doc: *const Document,
    seen: [generator.max_elements][generator.max_records]bool = std.mem.zeroes([generator.max_elements][generator.max_records]bool),
    total: usize = 0,
    batches: u64 = 0,
    ordered: bool,
    next_element: usize = 0,
    next_record: [generator.max_elements]usize = @splat(0),

    fn accept(self: *Tracker, batch: *const Batch) !void {
        try checkBatch(self.doc, batch);
        const info = batch.info();
        const e = info.element_index;
        const start: usize = @intCast(info.first_record);
        if (self.ordered) {
            try std.testing.expectEqual(self.batches, info.sequence);
            try std.testing.expect(e >= self.next_element);
            try std.testing.expectEqual(self.next_record[e], start);
            self.next_element = e;
            self.next_record[e] += info.record_count;
        }
        for (start..start + info.record_count) |r| {
            try std.testing.expect(!self.seen[e][r]);
            self.seen[e][r] = true;
        }
        self.total += info.record_count;
        self.batches += 1;
    }

    fn finish(self: *const Tracker) !void {
        var expected: usize = 0;
        for (self.doc.elements[0..self.doc.element_count], 0..) |element, e| {
            expected += element.count;
            for (0..element.count) |r| try std.testing.expect(self.seen[e][r]);
            if (self.ordered) try std.testing.expectEqual(element.count, self.next_record[e]);
        }
        try std.testing.expectEqual(expected, self.total);
    }
};

fn assertBudget(parser: *const Parser) !void {
    const stats = parser.memoryStats();
    try std.testing.expect(stats.live_bytes <= stats.budget_bytes);
    try std.testing.expect(stats.reserved_bytes <= stats.budget_bytes - stats.live_bytes);
    try std.testing.expect(stats.peak_total_bytes <= stats.budget_bytes);
}

fn exercise(doc: *const Document, io: std.Io, kind: ReaderKind, chunk: usize, budget: usize, ordered: bool) !u64 {
    var fixed: std.Io.Reader = .fixed(doc.source());
    const pattern: []const usize = switch (kind) {
        .fixed, .one_byte => &.{1},
        .primes => &.{ 2, 3, 5, 7 },
        .irregular => &.{ 64, 1, 128, 3 },
    };
    var fragmented = support.FragmentingReader.init(doc.source(), pattern, 0);
    const reader: *std.Io.Reader = if (kind == .fixed) &fixed else fragmented.reader();
    var parser = try Parser.init(std.testing.allocator, io, reader, .{
        .chunk_size = chunk,
        .memory_budget = budget,
        .preserve_order = ordered,
    });
    defer parser.deinit();

    var tracker: Tracker = .{ .doc = doc, .ordered = ordered };
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        try tracker.accept(&batch);
        try assertBudget(&parser);
    }
    try tracker.finish();
    try assertBudget(&parser);
    try std.testing.expect((try parser.next()) == null);
    // Only the declared body is logically consumed, not the trailing marker.
    inline for ("TAIL") |byte| try std.testing.expectEqual(@as(u8, byte), try reader.takeByte());
    return tracker.batches;
}

fn withComment(original: *const Document) !Document {
    var edited = original.*;
    const at = std.mem.indexOf(u8, original.source(), "end_header\n") orelse return error.MissingHeaderTerminator;
    const comment = "comment M11 irrelevant metadata 12345\n";
    if (edited.len + comment.len > edited.bytes.len) return error.GeneratedDocumentTooLarge;
    var pos = edited.len;
    while (pos > at) {
        pos -= 1;
        edited.bytes[pos + comment.len] = edited.bytes[pos];
    }
    @memcpy(edited.bytes[at..][0..comment.len], comment);
    edited.len += comment.len;
    edited.body_start += comment.len;
    return edited;
}

test "M11 reader fragmentation, batch partition and budget invariance" {
    inline for (.{ Encoding.ascii, Encoding.binary_little_endian, Encoding.binary_big_endian }) |encoding| {
        for (0..18) |n| {
            const doc = try Document.generate(@intCast(n), encoding);
            const baseline = try exercise(&doc, std.testing.io, .fixed, 512, 2 * 1024 * 1024, true);
            _ = try exercise(&doc, std.testing.io, .one_byte, 64, 2 * 1024 * 1024, true);
            _ = try exercise(&doc, std.testing.io, .primes, 128, 2 * 1024 * 1024, true);
            _ = try exercise(&doc, std.testing.io, .irregular, 256, 2 * 1024 * 1024, true);
            _ = try exercise(&doc, std.testing.io, .fixed, 64, 512 * 1024, true);
            _ = try exercise(&doc, std.testing.io, .fixed, 256, 4 * 1024 * 1024, false);
            try std.testing.expect(baseline > 0);
        }
    }
}

test "M11 same logical records survive endian and comment-only transformations" {
    for (0..24) |n| {
        const seed: u64 = @intCast(n);
        const ascii = try Document.generate(seed, .ascii);
        const little = try Document.generate(seed, .binary_little_endian);
        const big = try Document.generate(seed, .binary_big_endian);
        // The source generator is independent of the parser. Its cells are
        // constructed before either binary serialization takes place.
        for (ascii.elements[0..ascii.element_count], 0..) |element, e| {
            try std.testing.expectEqual(element.count, little.elements[e].count);
            try std.testing.expectEqual(element.count, big.elements[e].count);
            for (0..element.count) |r| {
                for (0..element.property_count) |p| {
                    const reference = ascii.cells[e][r][p];
                    try std.testing.expectEqual(reference.len, little.cells[e][r][p].len);
                    try std.testing.expectEqual(reference.len, big.cells[e][r][p].len);
                    try std.testing.expectEqualSlices(u64, reference.bits[0..reference.len], little.cells[e][r][p].bits[0..reference.len]);
                    try std.testing.expectEqualSlices(u64, reference.bits[0..reference.len], big.cells[e][r][p].bits[0..reference.len]);
                }
            }
        }
        inline for (.{ Encoding.ascii, Encoding.binary_little_endian, Encoding.binary_big_endian }) |encoding| {
            const doc = switch (encoding) {
                .ascii => &ascii,
                .binary_little_endian => &little,
                .binary_big_endian => &big,
            };
            const modified = try withComment(doc);
            _ = try exercise(doc, std.testing.io, .fixed, 64, 2 * 1024 * 1024, true);
            _ = try exercise(&modified, std.testing.io, .fixed, 64, 2 * 1024 * 1024, true);
        }
    }
}

test "M11 retained batch stays unchanged while subsequent batches are decoded" {
    const doc = try Document.generate(1, .binary_little_endian);
    var reader: std.Io.Reader = .fixed(doc.source());
    var parser = try Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 64,
        .memory_budget = 4 * 1024 * 1024,
    });
    defer parser.deinit();
    var first = (try parser.next()) orelse return error.MissingFirstBatch;
    defer first.release();
    try checkBatch(&doc, &first);
    var batches: usize = 1;
    while (try parser.next()) |value| {
        var later = value;
        defer later.release();
        try checkBatch(&doc, &later);
        // First is still leased, so pool reuse must not corrupt it.
        try checkBatch(&doc, &first);
        batches += 1;
    }
    try std.testing.expect(batches > 1);
    try checkBatch(&doc, &first);
    try assertBudget(&parser);
}

fn makeLarge(allocator: std.mem.Allocator, count: usize, endian: std.builtin.Endian) ![]u8 {
    const format = if (endian == .little) "binary_little_endian" else "binary_big_endian";
    const header = try std.fmt.allocPrint(allocator,
        "ply\nformat {s} 1.0\nelement sample {d}\n" ++
            "property float x\nproperty list uchar int ids\nproperty ushort label\nend_header\n",
        .{ format, count },
    );
    defer allocator.free(header);
    // 4 + 1 + 3*4 + 2 = 19 bytes maximum per record.
    const data = try allocator.alloc(u8, header.len + 19 * count + 4);
    errdefer allocator.free(data);
    @memcpy(data[0..header.len], header);
    var pos: usize = header.len;
    for (0..count) |i| {
        const x: f32 = @floatFromInt(i);
        std.mem.writeInt(u32, data[pos..][0..4], @bitCast(x), endian);
        pos += 4;
        const n: usize = i % 4;
        data[pos] = @intCast(n);
        pos += 1;
        for (0..n) |j| {
            std.mem.writeInt(u32, data[pos..][0..4], @intCast(i * 4 + j), endian);
            pos += 4;
        }
        std.mem.writeInt(u16, data[pos..][0..2], @intCast(i % 65536), endian);
        pos += 2;
    }
    @memcpy(data[pos..][0..4], "TAIL");
    return allocator.realloc(data, pos + 4);
}

fn checkLarge(bytes: []const u8, io: std.Io, ordered: bool, require_native: bool) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try Parser.init(std.testing.allocator, io, &reader, .{
        .chunk_size = 128 * 1024,
        .memory_budget = 4 * 1024 * 1024,
        .preserve_order = ordered,
    });
    defer parser.deinit();
    const count: usize = 40_000;
    const seen = try std.testing.allocator.alloc(bool, count);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var next_sequence: u64 = 0;
    var next_record: usize = 0;
    var batches: usize = 0;
    while (try parser.next()) |value| {
        var batch = value;
        defer batch.release();
        const info = batch.info();
        try std.testing.expectEqual(@as(usize, 0), info.element_index);
        if (ordered) {
            try std.testing.expectEqual(next_sequence, info.sequence);
            try std.testing.expectEqual(next_record, @as(usize, @intCast(info.first_record)));
            next_sequence += 1;
            next_record += info.record_count;
        }
        const x = try batch.typedColumn(f32, 0);
        const ids = try batch.listColumn(1);
        const label = try batch.typedColumn(u16, 2);
        try std.testing.expectEqual(info.record_count + 1, ids.offsets.len);
        for (x, label, 0..) |vx, vl, row| {
            const r: usize = @as(usize, @intCast(info.first_record)) + row;
            try std.testing.expect(r < count);
            try std.testing.expect(!seen[r]);
            seen[r] = true;
            try std.testing.expectEqual(@as(f32, @floatFromInt(r)), vx);
            try std.testing.expectEqual(@as(u16, @intCast(r % 65536)), vl);
            const cell = ids.row(row) orelse return error.MissingLargeList;
            try std.testing.expectEqual(r % 4, cell.i32.len);
            for (cell.i32, 0..) |item, j|
                try std.testing.expectEqual(@as(i32, @intCast(r * 4 + j)), item);
        }
        batches += 1;
        try assertBudget(&parser);
    }
    try std.testing.expect(batches > 1);
    if (ordered) try std.testing.expectEqual(count, next_record);
    for (seen) |visited| try std.testing.expect(visited);
    if (require_native) try std.testing.expect(parser.executionStats().native_submissions > 0);
    inline for ("TAIL") |byte| try std.testing.expectEqual(@as(u8, byte), try reader.takeByte());
}

test "M11 threaded ordered/unordered and fallback decode the same large variable-list stream" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        const bytes = try makeLarge(std.testing.allocator, 40_000, endian);
        defer std.testing.allocator.free(bytes);
        try checkLarge(bytes, std.testing.io, true, false);
        try checkLarge(bytes, std.testing.io, false, false);
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(4) });
        defer threaded.deinit();
        try checkLarge(bytes, threaded.io(), true, true);
        try checkLarge(bytes, threaded.io(), false, true);
    }
}

fn errorCategory(io: std.Io, data: []const u8, ordered: bool, chunk: usize, require_native: bool) !internal.errors.Diagnostic.Category {
    var reader: std.Io.Reader = .fixed(data);
    var parser = try Parser.init(std.testing.allocator, io, &reader, .{
        .chunk_size = chunk,
        .memory_budget = 4 * 1024 * 1024,
        .preserve_order = ordered,
    });
    defer parser.deinit();
    while (true) {
        const maybe = parser.next() catch |err| {
            if (require_native) try std.testing.expect(parser.executionStats().native_submissions > 0);
            const diagnostic = parser.lastDiagnostic() orelse return error.MissingFailureDiagnostic;
            try std.testing.expectEqual(@as(anyerror, err), diagnostic.code.?);
            return diagnostic.category;
        };
        var batch = maybe orelse return error.ExpectedMalformedInput;
        batch.release();
    }
}

test "M11 malformed input category agrees across fallback and native execution" {
    const malformed = [_][]const u8{
        "ply\nformat ascii 1.0\nelement sample 1\nproperty int value\nend_header\ninvalid\n",
        "ply\nformat binary_little_endian 1.0\nelement sample 1\nproperty double x\nend_header\n\x00\x01",
        "ply\nformat binary_big_endian 1.0\nelement sample 1\nproperty list uchar int values\nend_header\n\x02\x00\x00",
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(4) });
    defer threaded.deinit();
    for (malformed) |data| {
        const baseline = try errorCategory(std.testing.io, data, true, 64, false);
        try std.testing.expectEqual(baseline, try errorCategory(std.testing.io, data, false, 64, false));
        try std.testing.expectEqual(baseline, try errorCategory(threaded.io(), data, true, 64, false));
        try std.testing.expectEqual(baseline, try errorCategory(threaded.io(), data, false, 64, false));
    }
}

test "M11 truncated final binary record has consistent category after native read-ahead" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(4) });
    defer threaded.deinit();
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        const bytes = try makeLarge(std.testing.allocator, 40_000, endian);
        defer std.testing.allocator.free(bytes);
        // Remove the trailing marker and the last two bytes of the final
        // record. Earlier complete chunks may already be in flight.
        const truncated = bytes[0 .. bytes.len - 4 - 2];
        const baseline = try errorCategory(std.testing.io, truncated, true, 128 * 1024, false);
        try std.testing.expectEqual(internal.errors.Diagnostic.Category.truncation, baseline);
        try std.testing.expectEqual(baseline, try errorCategory(std.testing.io, truncated, false, 128 * 1024, false));
        try std.testing.expectEqual(baseline, try errorCategory(threaded.io(), truncated, true, 128 * 1024, true));
        try std.testing.expectEqual(baseline, try errorCategory(threaded.io(), truncated, false, 128 * 1024, true));
    }
}

fn fuzzMetamorphic(_: void, smith: *std.testing.Smith) !void {
    const seed = smith.value(u64);
    const encoding: Encoding = @enumFromInt(smith.valueRangeAtMost(u8, 0, 2));
    const chunk: usize = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => 64, 1 => 128, else => 512,
    };
    const doc = try Document.generate(seed, encoding);
    _ = try exercise(&doc, std.testing.io, .fixed, 512, 2 * 1024 * 1024, true);
    _ = try exercise(&doc, std.testing.io, .primes, chunk, 512 * 1024, false);
    const modified = try withComment(&doc);
    _ = try exercise(&modified, std.testing.io, .one_byte, chunk, 2 * 1024 * 1024, true);
}

test "M11 fuzz metamorphic reader, budget, and metadata transformations" {
    try std.testing.fuzz({}, fuzzMetamorphic, .{});
}
