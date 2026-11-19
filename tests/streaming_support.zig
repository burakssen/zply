//! Shared support for the Phase 4 streaming test suites: reader doubles,
//! deterministic binary fixtures, and the chunk-streaming verification
//! harness.
//!
//! The reader doubles are hand-rolled `std.Io.Reader` implementations with
//! empty internal buffers, so every byte delivery is a genuine underlying
//! read with the requested size pattern — exactly the fragmentation the
//! producer must be robust against.
//!
//! All streaming test files use the `zply_internals` universe exclusively
//! (see `internals.zig`'s universe-mixing note). The public `zply` module is
//! never imported here.

const std = @import("std");
pub const internals = @import("zply_internals");

pub const Parser = internals.parser.Parser;
pub const Options = internals.options.Options;
pub const input = internals.input;
pub const decode = internals.decode;
pub const types = internals.types;
pub const RawChunk = input.RawChunk;

// ---------------------------------------------------------------------------
// Reader doubles
// ---------------------------------------------------------------------------

const fragmenting_vtable = std.Io.Reader.VTable{
    .stream = fragmentingStream,
};

/// A reader that delivers its source through underlying reads whose sizes
/// follow a repeating pattern, e.g. `&.{1, 2, 5, 7}` or `&.{1}` (byte at a
/// time). The fragment sizes are underlying input boundaries, deliberately
/// unrelated to PLY record boundaries. The internal buffer stays empty, so
/// every delivery is a short underlying read the producer must loop over.
pub const FragmentingReader = struct {
    source: []const u8,
    position: usize = 0,
    pattern: []const usize,
    pattern_index: usize = 0,
    bytes_into_fragment: usize = 0,
    buffer: [1]u8 = undefined,
    base: std.Io.Reader,

    /// `start` skips leading source bytes (a reader composited after
    /// something else already consumed a prefix).
    pub fn init(source: []const u8, pattern: []const usize, start: usize) FragmentingReader {
        return .{
            .source = source,
            .position = start,
            .pattern = pattern,
            .base = .{
                .vtable = &fragmenting_vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *FragmentingReader) *std.Io.Reader {
        self.base.buffer = &self.buffer;
        return &self.base;
    }

    fn advance(self: *FragmentingReader, n: usize) void {
        self.position += n;
        const frag = self.pattern[self.pattern_index % self.pattern.len];
        self.bytes_into_fragment += n;
        if (self.bytes_into_fragment >= frag) {
            self.pattern_index += 1;
            self.bytes_into_fragment = 0;
        }
    }
};

fn fragmentingStream(
    base: *std.Io.Reader,
    w: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const self: *FragmentingReader = @alignCast(@fieldParentPtr("base", base));
    const source_remaining = self.source.len - self.position;
    if (source_remaining == 0) return error.EndOfStream;
    const frag = self.pattern[self.pattern_index % self.pattern.len];
    const frag_remaining = frag - self.bytes_into_fragment;
    const want = @min(@min(@backingInt(limit), frag_remaining), source_remaining);
    if (want == 0) return error.EndOfStream;
    const written = try w.write(self.source[self.position..][0..want]);
    self.advance(written);
    return written;
}

fn fragmentingReadVec(
    base: *std.Io.Reader,
    data: [][]u8,
) std.Io.Reader.Error!usize {
    const self: *FragmentingReader = @alignCast(@fieldParentPtr("base", base));
    var total: usize = 0;
    for (data) |dest| {
        if (dest.len == 0) continue;
        const source_remaining = self.source.len - self.position;
        if (source_remaining == 0) {
            if (total == 0) return error.EndOfStream;
            break;
        }
        const frag = self.pattern[self.pattern_index % self.pattern.len];
        const frag_remaining = frag - self.bytes_into_fragment;
        const n = @min(@min(dest.len, frag_remaining), source_remaining);
        if (n == 0) {
            if (total == 0) return error.EndOfStream;
            break;
        }
        @memcpy(dest[0..n], self.source[self.position..][0..n]);
        self.advance(n);
        total += n;
        if (n < dest.len) break;
    }
    return total;
}

fn fragmentingRebase(
    base: *std.Io.Reader,
    capacity: usize,
) std.Io.Reader.RebaseError!void {
    _ = base;
    _ = capacity;
    // The fragmenting reader never buffers; nothing to relocate.
}

// Standalone reader double shared by public-API and internal-only tests.
// Unlike this streaming support module, failing_reader.zig imports no
// parser modules, so public tests can use it without overlapping modules.
pub const FailingReader = @import("failing_reader.zig").FailingReader;

// ---------------------------------------------------------------------------
// Deterministic binary fixtures
// ---------------------------------------------------------------------------

/// Writes one scalar of type `T` in the given byte order.
pub fn writeScalar(
    comptime T: type,
    endian: std.builtin.Endian,
    value: T,
    dest: []u8,
) void {
    const UnsignedT = @Int(.unsigned, @bitSizeOf(T));
    const bits: UnsignedT = @bitCast(value);
    std.mem.writeInt(UnsignedT, dest[0..@sizeOf(T)], bits, endian);
}

/// Writes `count` XYZ records (three `T` scalars) whose coordinates are
/// deterministic functions of the record index: x = i, y = 2i, z = -i.
/// `out` must hold exactly `count * 3 * @sizeOf(T)` bytes.
pub fn writeXyzBody(
    comptime T: type,
    endian: std.builtin.Endian,
    count: u64,
    out: []u8,
) void {
    const width = 3 * @sizeOf(T);
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const record = out[@intCast(i * width)..][0..width];
        const x: T = @floatFromInt(i);
        const y: T = @floatFromInt(2 * i);
        const z: T = -@as(T, @floatFromInt(i));
        writeScalar(T, endian, x, record[0..@sizeOf(T)]);
        writeScalar(T, endian, y, record[@sizeOf(T)..][0..@sizeOf(T)]);
        writeScalar(T, endian, z, record[2 * @sizeOf(T) ..][0..@sizeOf(T)]);
    }
}

/// The expected XYZ coordinate triple for record index `i` (see
/// `writeXyzBody`).
pub fn expectedXyz(comptime T: type, record_index: u64) [3]T {
    return .{
        @floatFromInt(record_index),
        @floatFromInt(2 * record_index),
        -@as(T, @floatFromInt(record_index)),
    };
}

/// Asserts that a decoded `RecordView` matches the expected XYZ triple.
pub fn expectXyzRecord(
    comptime T: type,
    record_index: u64,
    view: decode.RecordView,
) !void {
    var values: [3]decode.ScalarValue = undefined;
    try view.decodeAll(&values);
    const expected = expectedXyz(T, record_index);
    inline for (0..3) |axis| {
        const decoded = @field(values[axis], @typeName(T));
        // Exact equality: the values were produced by exactly the same
        // integer→float conversion on both sides.
        try std.testing.expectEqual(expected[axis], decoded);
    }
}

// ---------------------------------------------------------------------------
// Chunk-streaming verification harness
// ---------------------------------------------------------------------------

/// Running statistics and invariant checks for a full streaming pass.
pub const StreamStats = struct {
    chunks: u64 = 0,
    records: u64 = 0,
    body_bytes: u64 = 0,

    /// Sequence-aware checksum: every chunk's sequence, record range,
    /// element index, and byte content are folded in, so gaps,
    /// duplicates, and reorderings change the final value. Combined with
    /// the exact record count and sampled assertions this catches
    /// skipping/reordering that a plain data hash would conceal.
    hash: u64 = 0x706C7934, // "ply4"

    // Traversal bookkeeping for the invariant checks in `streamAll`.
    next_expected_sequence: u64 = 0,
    next_expected_offset: ?u64 = null,
    last_element: ?usize = null,
    last_element_end: u64 = 0,
};

fn mix(stats: *StreamStats, chunk: RawChunk) void {
    stats.hash = std.hash.Wyhash.hash(stats.hash, std.mem.asBytes(&chunk.sequence));
    stats.hash = std.hash.Wyhash.hash(stats.hash, std.mem.asBytes(&chunk.element_index));
    stats.hash = std.hash.Wyhash.hash(stats.hash, std.mem.asBytes(&chunk.first_record));
    stats.hash = std.hash.Wyhash.hash(stats.hash, std.mem.asBytes(&chunk.record_count));
    stats.hash = std.hash.Wyhash.hash(stats.hash, chunk.bytes);
}

/// Streams the parser's whole body through `nextRawChunk`, asserting every
/// chunk invariant from the RawChunk contract, and calling `consumer`
/// (record index within the element, `RecordView`) for every decoded
/// record. Records are decoded with the Phase 3 fixed-layout decoder —
/// the intended Reader → chunk → decoder pipeline.
pub fn streamAll(
    parser: *Parser,
    stats: *StreamStats,
    context: anytype,
    comptime consumer: fn (@TypeOf(context), element_index: usize, record_index: u64, view: decode.RecordView) anyerror!void,
) !void {
    const header = parser.header();
    const layouts = parser.layouts();

    if (stats.next_expected_offset == null) {
        stats.next_expected_offset = header.body_offset;
    }

    while (try internals.parser.nextRawChunkForTesting(parser)) |chunk| {
        // Gapless, globally monotonic sequence.
        try std.testing.expectEqual(stats.next_expected_sequence, chunk.sequence);
        stats.next_expected_sequence += 1;

        // PLY-relative byte offsets advance exactly by the bytes consumed.
        try std.testing.expectEqual(stats.next_expected_offset.?, chunk.byte_offset);
        stats.next_expected_offset.? += chunk.bytes.len;

        try std.testing.expect(chunk.record_count > 0);

        // Element progress: same element with continuing record indices,
        // or a later element (zero-count elements may be skipped, so the
        // index may advance by more than one).
        if (stats.last_element) |last| {
            if (chunk.element_index == last) {
                try std.testing.expectEqual(stats.last_element_end, chunk.first_record);
            } else {
                try std.testing.expect(chunk.element_index > last);
                try std.testing.expectEqual(@as(u64, 0), chunk.first_record);
            }
        } else {
            try std.testing.expectEqual(@as(u64, 0), chunk.first_record);
        }

        // The chunk stays within its element's declared record count, is
        // single-element by construction, and has the exact byte length.
        const element_count = header.elements[chunk.element_index].count;
        const range_end = std.math.add(u64, chunk.first_record, chunk.record_count) catch
            return error.SizeOverflow;
        try std.testing.expect(range_end <= element_count);

        const element_layout = &layouts[chunk.element_index];
        const width = element_layout.fixed_record_size orelse
            return error.UnsupportedVariableLengthElement;
        try chunk.validateAgainstWidth(width);

        // Decode with the Phase 3 decoder over the borrowed bytes.
        const fixed = try decode.FixedLayout.initForEncoding(element_layout, header.encoding);
        const ChunkCtx = struct {
            outer: @TypeOf(context),
            element_index: usize,
            first_record: u64,
        };
        var chunk_ctx: ChunkCtx = .{
            .outer = context,
            .element_index = chunk.element_index,
            .first_record = chunk.first_record,
        };
        try decode.decodeRange(fixed, chunk.bytes, chunk.record_count, &chunk_ctx, struct {
            fn visit(
                cc: *ChunkCtx,
                local_index: u64,
                view: decode.RecordView,
            ) anyerror!void {
                return consumer(cc.outer, cc.element_index, cc.first_record + local_index, view);
            }
        }.visit);

        mix(stats, chunk);
        stats.chunks += 1;
        stats.records += chunk.record_count;
        stats.body_bytes += chunk.bytes.len;
        stats.last_element = chunk.element_index;
        stats.last_element_end = range_end;
    }

    // `null` means declared completion — the parser must agree.
    try std.testing.expectEqual(@as(internals.parser.Parser.State, .completed), parser.state);
}

/// Streams the parser's whole body, verifying every record against the
/// deterministic XYZ fixture (`writeXyzBody`/`expectedXyz`) and accumulating
/// `StreamStats`. The first and last record of every chunk are also asserted
/// exactly (sampled exact-value assertions in addition to the checksum).
pub fn verifyXyzStream(
    comptime T: type,
    parser: *Parser,
    stats: *StreamStats,
    declared_count: u64,
) !void {
    var first_seen: ?u64 = null;
    var local_last: u64 = 0;
    const Ctx = struct {
        first_seen: *?u64,
        local_last: *u64,
    };
    const ctx: Ctx = .{ .first_seen = &first_seen, .local_last = &local_last };
    try streamAll(parser, stats, ctx, struct {
        fn visit(c: Ctx, element_index: usize, record_index: u64, view: decode.RecordView) anyerror!void {
            _ = element_index;
            if (c.first_seen.* == null) c.first_seen.* = record_index;
            c.local_last.* = record_index;
            try expectXyzRecord(T, record_index, view);
        }
    }.visit);

    try std.testing.expectEqual(declared_count, stats.records);
    try std.testing.expectEqual(@as(u64, 0), first_seen.?);
    try std.testing.expectEqual(declared_count - 1, local_last);
}
