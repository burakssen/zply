//! The streaming producer state machine (Tasks 4.5–4.10).
//!
//! The producer is the only component that advances the caller's
//! reader: it walks the PLY body element by element in header order,
//! plans complete-record chunks, reads exactly the bytes those chunks
//! need, and emits `RawChunk` descriptors for the Phase 3 decoder.
//!
//! Design rules carried over from the phase spec:
//!
//! * **No self-referential pointers.** `Parser.init()` returns the
//!   parser by value, so the producer stores only stream-progress
//!   counters — never pointers into the enclosing parser. The reader,
//!   header, and layouts are passed into its operations per call.
//! * **Transactional progress.** Counters commit only after the bytes
//!   for a chunk have been received. A truncated read may have consumed
//!   some bytes from the caller's reader (unrecoverable on non-seekable
//!   sources), so the producer enters the `failed` state, emits no
//!   partial chunk, and commits no record count.
//! * **Completion is declared, not observed.** The producer finishes
//!   when every declared record has been emitted — including zero-width
//!   logical records — never when the source reaches EOF. Trailing
//!   bytes after the last declared record are left unread.
//! * **Format-structural only.** The producer never byte-swaps or
//!   interprets record content; the Phase 3 decoder owns the declared
//!   encoding's endianness.

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const planner_mod = @import("planner.zig");

const header_mod = @import("../format/header.zig");
const layout_mod = @import("../format/layout.zig");
const options_mod = @import("../options.zig");

const Header = header_mod.Header;
const ElementLayout = layout_mod.ElementLayout;
const Options = options_mod.Options;
const RawChunk = chunk_mod.RawChunk;
const ChunkPlan = planner_mod.ChunkPlan;

/// Errors the streaming producer can report. I/O failures, invalid
/// files, unsupported layouts, and memory constraints are distinct;
/// nothing is collapsed into one generic invalid-file error.
pub const ProducerError = error{
    /// EOF arrived before the bytes required by the planned chunk did.
    /// Some prefix of the chunk may already have been consumed from the
    /// caller's reader; the producer is `failed` afterwards.
    TruncatedBody,
    /// The underlying reader reported an I/O failure.
    ReadFailed,
    /// An ASCII body was handed to the binary producer.
    UnsupportedEncoding,
    /// A nonempty element containing list properties was reached; the
    /// list boundary scanner arrives in Phase 10.
    UnsupportedVariableLengthElement,
    /// A single record exceeds the configured record-size limit.
    RecordTooLarge,
    /// The destination cannot hold even one record of the plan.
    InsufficientBufferCapacity,
    /// Offset, count, or size arithmetic overflowed.
    SizeOverflow,
    /// A configured resource limit prevents progress.
    ResourceLimitExceeded,
    /// The operation is invalid for the producer's current state (e.g.
    /// reading after a terminal failure, or a stale plan).
    InvalidProducerState,
    /// Buffer allocation failed.
    OutOfMemory,
};

/// Stream progress through the PLY body.
pub const Producer = struct {
    /// Current element (header order).
    element_index: usize = 0,

    /// Next record index within the current element. Invariant:
    /// `0 <= next_record <= element.count`, reset to 0 on element
    /// advance.
    next_record: u64 = 0,

    /// Sequence number of the next chunk. Global across the whole body;
    /// never resets between elements.
    sequence: u64 = 0,

    /// Successfully consumed PLY body bytes.
    body_bytes_consumed: u64 = 0,

    /// Producer lifecycle state.
    state: State = .ready,

    /// Details of the most recent failed body read. A read failure can
    /// leave the physical reader position unknown.
    failure: ?Failure = null,

    pub const Failure = struct {
        element_index: usize,
        first_record: u64,
        byte_offset: u64,
        requested_bytes: u64,
        received_bytes: ?usize,
    };

    pub const State = enum {
        /// Constructed; no chunk planned or read yet.
        ready,
        /// At least one chunk was successfully emitted.
        reading,
        /// Every declared record was emitted successfully.
        completed,
        /// A streaming failure terminated progress. Terminal: no more
        /// chunks are emitted and no state is reset.
        failed,
    };

    /// Plans the next chunk without reading anything.
    ///
    /// Returns `null` when every declared record (of every element,
    /// including zero-width logical records) has been emitted — that is
    /// *successful completion*, not EOF. Zero-count elements are
    /// skipped here: they declare no body bytes and no records, so
    /// advancing past them commits nothing.
    ///
    /// A nonempty ASCII element or a nonempty variable-length element
    /// is an explicit error — never skipped (that would corrupt the
    /// reader's logical position).
    pub fn planNext(
        self: *Producer,
        header: *const Header,
        layouts: []const ElementLayout,
        options: Options,
    ) ProducerError!?ChunkPlan {
        switch (self.state) {
            .ready, .reading => {},
            .completed => return null,
            .failed => return error.InvalidProducerState,
        }

        if (header.encoding == .ascii) {
            self.state = .failed;
            return error.UnsupportedEncoding;
        }
        if (layouts.len != header.elements.len) return error.InvalidProducerState;

        // Skip zero-count elements; they occupy no body bytes and no
        // logical records.
        while (self.element_index < layouts.len) {
            const element = header.elements[self.element_index];
            if (element.count != 0) break;
            self.element_index += 1;
            self.next_record = 0;
        }
        if (self.element_index >= layouts.len) {
            self.state = .completed;
            return null;
        }

        const element = header.elements[self.element_index];
        const layout = &layouts[self.element_index];

        // Phase 4 supports binary bodies only (ASCII body streaming and
        // list-bearing elements arrive in later phases). Both are
        // deterministic schema-level failures — no bytes are consumed,
        // but no retry within this stream can succeed either, so the
        // producer marks itself failed.
        const record_width = layout.fixed_record_size orelse {
            self.state = .failed;
            return error.UnsupportedVariableLengthElement;
        };

        // Progress invariants (internal, but checked — never `assert`ed
        // against externally influenced state).
        if (self.next_record > element.count) return error.InvalidProducerState;
        const remaining = element.count - self.next_record;
        if (remaining == 0) {
            // The element was fully emitted but not yet advanced;
            // advance past it and retry (cannot loop: count > 0 and
            // next_record < count now holds after the advance).
            self.element_index += 1;
            self.next_record = 0;
            return self.planNext(header, layouts, options);
        }

        const byte_offset = std.math.add(
            u64,
            header.body_offset,
            self.body_bytes_consumed,
        ) catch return error.SizeOverflow;

        return planner_mod.planChunk(
            self.element_index,
            self.next_record,
            element.count,
            remaining,
            record_width,
            options.chunk_size,
            options.limits.max_record_bytes,
            byte_offset,
            self.sequence,
        ) catch |err| switch (err) {
            error.RecordTooLarge => error.RecordTooLarge,
            error.SizeOverflow => error.SizeOverflow,
        };
    }

    /// Reads exactly the planned chunk's bytes and commits progress.
    ///
    /// Sequence: validate the plan against the producer's position,
    /// validate the destination capacity, read, construct the chunk,
    /// commit counters, return the descriptor. Nothing commits before
    /// the read succeeds; a failed read leaves no partial successful
    /// chunk and no advanced record counter.
    ///
    /// `destination` must hold at least `plan.byte_count` bytes. A
    /// zero-byte plan never touches the reader (zero-width records make
    /// logical progress without input; a zero-length read says nothing
    /// about EOF and is not used to detect it).
    pub fn readPlanned(
        self: *Producer,
        reader: *std.Io.Reader,
        plan: ChunkPlan,
        destination: []u8,
        element_record_count: u64,
    ) ProducerError!RawChunk {
        switch (self.state) {
            .ready, .reading => {},
            .completed, .failed => return error.InvalidProducerState,
        }

        // The plan must describe this producer's current position.
        if (plan.element_index != self.element_index or
            plan.first_record != self.next_record or
            plan.sequence != self.sequence or
            plan.record_count == 0 or
            plan.element_record_count != element_record_count)
        {
            return error.InvalidProducerState;
        }

        const next_record = std.math.add(u64, self.next_record, plan.record_count) catch return error.SizeOverflow;
        if (next_record > element_record_count) return error.InvalidProducerState;
        const next_bytes = std.math.add(u64, self.body_bytes_consumed, plan.byte_count) catch return error.SizeOverflow;
        const next_sequence = std.math.add(u64, self.sequence, 1) catch return error.SizeOverflow;
        _ = std.math.add(u64, plan.byte_offset, plan.byte_count) catch return error.SizeOverflow;
        if (plan.byte_count > 0) {
            const byte_count = std.math.cast(usize, plan.byte_count) orelse
                return error.SizeOverflow;
            if (destination.len < byte_count) {
                return error.InsufficientBufferCapacity;
            }

            // readSliceShort loops over fragmented underlying reads and
            // returns the count actually received; a short count means
            // EOF ended the stream before the chunk was complete.
            const received = reader.readSliceShort(destination[0..byte_count]) catch |err| switch (err) {
                error.ReadFailed => {
                    self.failure = .{
                        .element_index = plan.element_index,
                        .first_record = plan.first_record,
                        .byte_offset = plan.byte_offset,
                        .requested_bytes = plan.byte_count,
                        .received_bytes = null,
                    };
                    self.state = .failed;
                    return error.ReadFailed;
                },
            };
            if (received != byte_count) {
                self.failure = .{
                    .element_index = plan.element_index,
                    .first_record = plan.first_record,
                    .byte_offset = plan.byte_offset,
                    .requested_bytes = plan.byte_count,
                    .received_bytes = received,
                };
                self.state = .failed;
                return error.TruncatedBody;
            }
        }

        const chunk: RawChunk = .{
            .element_index = plan.element_index,
            .first_record = plan.first_record,
            .record_count = plan.record_count,
            .sequence = plan.sequence,
            .byte_offset = plan.byte_offset,
            .bytes = destination[0..@intCast(plan.byte_count)],
        };

        // Commit progress only after the read succeeded. Every update
        // is checked; an overflow here is a state failure, not silent
        // wrapping.
        self.next_record = next_record;
        if (self.next_record == element_record_count) {
            self.element_index += 1;
            self.next_record = 0;
        }
        self.body_bytes_consumed = next_bytes;
        self.sequence = next_sequence;
        self.state = .reading;

        return chunk;
    }

    /// Convenience combining `planNext` and `readPlanned` for a
    /// caller-provided destination with sufficient capacity.
    ///
    /// `null` means every declared record was consumed successfully
    /// (the underlying reader may still hold trailing data — that is
    /// never read or verified here).
    pub fn nextInto(
        self: *Producer,
        reader: *std.Io.Reader,
        header: *const Header,
        layouts: []const ElementLayout,
        destination: []u8,
        options: Options,
    ) ProducerError!?RawChunk {
        const plan = (try self.planNext(header, layouts, options)) orelse return null;
        return try self.readPlanned(
            reader,
            plan,
            destination,
            header.elements[plan.element_index].count,
        );
    }

    /// PLY-relative byte offset of the *next* chunk's first byte.
    pub fn nextByteOffset(self: *const Producer, header: *const Header) error{SizeOverflow}!u64 {
        return std.math.add(u64, header.body_offset, self.body_bytes_consumed) catch error.SizeOverflow;
    }
};

// ---------------------------------------------------------------------------
// Tests (module-level; full reader-backed suites live under tests/)
// ---------------------------------------------------------------------------

const header_parser = @import("../format/header_parser.zig");

const vertex_header = "ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\nproperty float y\nend_header\n";

/// 16 zero bytes: exactly two 8-byte vertex records.
const vertex_body: [16]u8 = @splat(0);
const vertex_full = vertex_header ++ vertex_body;

test "plan and read walk records in order with committed counters" {
    var reader: std.Io.Reader = .fixed(vertex_full);
    var storage = try header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();

    var producer = Producer{};
    var options = Options{};
    options.chunk_size = 16;

    const header = &storage.header;
    const layouts = storage.layouts;
    var destination: [64]u8 = undefined;

    // One chunk covers both declared records (2 × 8 B ≤ 16 B target).
    const chunk = (try producer.nextInto(&reader, header, layouts, &destination, options)).?;
    try std.testing.expectEqual(@as(usize, 0), chunk.element_index);
    try std.testing.expectEqual(@as(u64, 0), chunk.first_record);
    try std.testing.expectEqual(@as(u64, 0), chunk.sequence);
    try std.testing.expectEqual(header.body_offset, chunk.byte_offset);
    try std.testing.expectEqual(@as(u64, 2), chunk.record_count);
    try std.testing.expectEqual(@as(usize, 16), chunk.bytes.len);

    // Completion: both declared records were emitted. `null` is the
    // successful-completion signal — not EOF.
    const done = try producer.nextInto(&reader, header, layouts, &destination, options);
    try std.testing.expect(done == null);
    try std.testing.expectEqual(Producer.State.completed, producer.state);
    try std.testing.expectEqual(@as(u64, 16), producer.body_bytes_consumed);
    try std.testing.expectEqual(@as(u64, 1), producer.sequence);
}

test "chunking splits at record boundaries with monotonic sequence" {
    var reader: std.Io.Reader = .fixed(vertex_full);
    var storage = try header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();

    var producer = Producer{};
    var options = Options{};
    options.chunk_size = 12; // not a multiple of 8: rounds to 1 record per chunk

    const header = &storage.header;
    const layouts = storage.layouts;
    var destination: [64]u8 = undefined;

    var seen_sequence: u64 = 0;
    var records_seen: u64 = 0;
    var offset: u64 = header.body_offset;
    while (try producer.nextInto(&reader, header, layouts, &destination, options)) |chunk| {
        try std.testing.expectEqual(seen_sequence, chunk.sequence);
        try std.testing.expectEqual(records_seen, chunk.first_record);
        try std.testing.expectEqual(offset, chunk.byte_offset);
        try std.testing.expectEqual(@as(u64, 1), chunk.record_count);
        try std.testing.expectEqual(@as(usize, 8), chunk.bytes.len);
        seen_sequence += 1;
        records_seen += chunk.record_count;
        offset += chunk.bytes.len;
    }
    try std.testing.expectEqual(@as(u64, 2), records_seen);
    try std.testing.expectEqual(@as(u64, 2), seen_sequence);
    try std.testing.expectEqual(Producer.State.completed, producer.state);
}

test "truncated body: failed state, no committed chunk" {
    // The element declares 16 body bytes; only 4 exist.
    const four_zero_bytes = vertex_full[0 .. vertex_header.len + 4];
    var reader: std.Io.Reader = .fixed(four_zero_bytes);
    var storage = try header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();

    var producer = Producer{};
    var options = Options{};
    options.chunk_size = 16;

    const header = &storage.header;
    const layouts = storage.layouts;
    var destination: [64]u8 = undefined;

    // The element declares 16 body bytes; only 4 exist.
    try std.testing.expectError(
        error.TruncatedBody,
        producer.nextInto(&reader, header, layouts, &destination, options),
    );
    try std.testing.expectEqual(Producer.State.failed, producer.state);
    try std.testing.expectEqual(@as(u64, 0), producer.sequence);
    try std.testing.expectEqual(@as(u64, 0), producer.body_bytes_consumed);
    try std.testing.expectEqual(@as(u64, 0), producer.next_record);

    // Terminal: further reads are invalid, never a silent restart.
    try std.testing.expectError(
        error.InvalidProducerState,
        producer.nextInto(&reader, header, layouts, &destination, options),
    );
}

test "an element fully emitted advances to the next without a stale plan" {
    // A two-element file where the first element's last chunk exactly
    // completes it: the next plan must describe the second element.
    const text = "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "element vertex 2\n" ++
        "property float x\n" ++
        "property float y\n" ++
        "element camera 1\n" ++
        "property double px\n" ++
        "end_header\n";
    const body: [24]u8 = @splat(0);

    var reader: std.Io.Reader = .fixed(text ++ body);
    var storage = try header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();

    var producer = Producer{};
    var options = Options{};
    options.chunk_size = 16;

    const header = &storage.header;
    const layouts = storage.layouts;
    var destination: [64]u8 = undefined;

    // Chunk 1: both vertex records (16 B), completing the element.
    const vertex_chunk = (try producer.nextInto(&reader, header, layouts, &destination, options)).?;
    try std.testing.expectEqual(@as(usize, 0), vertex_chunk.element_index);
    try std.testing.expectEqual(@as(u64, 2), vertex_chunk.record_count);

    // Chunk 2: the camera element, record numbering restarted.
    const camera_chunk = (try producer.nextInto(&reader, header, layouts, &destination, options)).?;
    try std.testing.expectEqual(@as(usize, 1), camera_chunk.element_index);
    try std.testing.expectEqual(@as(u64, 0), camera_chunk.first_record);
    try std.testing.expectEqual(@as(u64, 1), camera_chunk.sequence);
    try std.testing.expectEqual(
        header.body_offset + vertex_chunk.bytes.len,
        camera_chunk.byte_offset,
    );

    // Completion.
    try std.testing.expect(
        (try producer.nextInto(&reader, header, layouts, &destination, options)) == null,
    );
    try std.testing.expectEqual(@as(u64, 24), producer.body_bytes_consumed);
}

test "zero-width logical records complete without any reader access" {
    const text = "ply\nformat binary_little_endian 1.0\nelement marker 100\nend_header\n";
    var reader: std.Io.Reader = .fixed(text);
    var storage = try header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();

    var producer = Producer{};
    const options = Options{};

    const header = &storage.header;
    const layouts = storage.layouts;
    var destination: [8]u8 = undefined;

    // 100 logical records, zero bytes: one bounded chunk (cap > 100).
    const chunk = (try producer.nextInto(&reader, header, layouts, &destination, options)).?;
    try std.testing.expectEqual(@as(u64, 100), chunk.record_count);
    try std.testing.expectEqual(@as(usize, 0), chunk.bytes.len);
    try std.testing.expectEqual(@as(u64, 0), producer.body_bytes_consumed);

    // The underlying reader was never touched: no body bytes existed.
    try std.testing.expect(
        (try producer.nextInto(&reader, header, layouts, &destination, options)) == null,
    );
    try std.testing.expectEqual(Producer.State.completed, producer.state);
}

test "planNext alone never reads; a stale plan cannot be executed twice" {
    var reader: std.Io.Reader = .fixed(vertex_full);
    var storage = try header_parser.parseHeader(std.testing.allocator, &reader, .{});
    defer storage.deinit();

    var producer = Producer{};
    var options = Options{};
    options.chunk_size = 16;

    const header = &storage.header;
    const layouts = storage.layouts;
    var destination: [64]u8 = undefined;

    const plan = (try producer.planNext(header, layouts, options)).?;
    try std.testing.expectEqual(@as(u64, 16), plan.byte_count);

    // Reading the plan commits it...
    _ = try producer.readPlanned(&reader, plan, &destination, 2);
    // ...and the same plan a second time no longer matches the
    // producer's position: explicit state error, never double-commit.
    try std.testing.expectError(
        error.InvalidProducerState,
        producer.readPlanned(&reader, plan, &destination, 2),
    );
}
