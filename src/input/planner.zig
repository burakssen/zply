//! The fixed-width chunk planner: pure sizing mathematics.
//!
//! The planner decides how many complete records form the next input
//! chunk. It is a pure function of its arguments: it never reads bytes,
//! never allocates, and never touches parser state — so it is testable
//! in isolation and reusable by any future execution strategy.
//!
//! Sizing rules (R = record width, C = target chunk bytes, N = remaining
//! records):
//!
//! * Normal element (R > 0): `K = max(1, C / R)` (floor), then
//!   `N_chunk = min(N, K)` and `B_chunk = N_chunk * R` (checked).
//! * Oversized record (R > C): never split a record to satisfy the
//!   preferred chunk size — plan exactly one record, provided R fits the
//!   configured `max_record_bytes` limit. The chunk size is a
//!   performance preference, not a record-size limit.
//! * Zero-width element (R == 0): no division, no bytes, no reads — a
//!   bounded number of *logical* records (a private cap) per chunk so
//!   the record counter always progresses toward completion.
//!
//! Capacity is handled in a second, separate step (`fitToCapacity`):
//! first select the desired record count, then ensure a buffer exists,
//! then finalize the count that actually fits. The planner never
//! assumes a buffer exists just because the logical chunk is valid.
//!
//! Every multiplication, addition, and width conversion is checked;
//! integer wrapping can never change the amount of data read.

const std = @import("std");

/// The next chunk's logical and byte dimensions.
pub const ChunkPlan = struct {
    /// Index of the element this chunk belongs to (header order).
    element_index: usize,

    /// First record index within the element.
    first_record: u64,

    /// Complete records in this chunk (always > 0).
    record_count: u64,

    /// Declared record count of the element the chunk belongs to. The
    /// reader (producer) validates the plan against this so a stale or
    /// forged plan cannot commit more records than the element
    /// declares.
    element_record_count: u64,

    /// Bytes to read for this chunk: `record_count * record_width`,
    /// or 0 for a zero-width element.
    byte_count: u64,

    /// PLY-relative byte offset of the chunk's first byte.
    byte_offset: u64,

    /// Sequence number this chunk will carry (monotonic across the body).
    sequence: u64,
};

/// Logical-record cap for zero-width elements: their chunks occupy no
/// bytes, so without a cap a single "chunk" would cover millions of
/// records in one planner step. Purely a pacing constant — not a
/// worker-count or concurrency setting.
const zero_width_chunk_records: u64 = 65536;

/// Errors the planner can report.
pub const PlanError = error{
    /// One record exceeds the configured `max_record_bytes` limit.
    RecordTooLarge,
    /// Offset/count/size arithmetic overflowed its integer type.
    SizeOverflow,
};

/// Computes the desired next chunk for a fixed-width element.
///
/// * `record_width` is the element's fixed per-record byte size (0 for
///   a zero-width element; the caller must not call this for
///   variable-width elements).
/// * `remaining` is how many records are still unread in the element
///   (must be > 0; zero remaining means "no chunk" and is decided by
///   the producer before planning).
/// * `max_record_bytes` is the configured per-record resource limit.
///
/// The result is a valid *desired* plan; it may still exceed the
/// current buffer's capacity, in which case the caller grows the buffer
/// (`fitToCapacity` finalizes the actual count).
pub fn planChunk(
    element_index: usize,
    first_record: u64,
    element_record_count: u64,
    remaining: u64,
    record_width: usize,
    target_chunk_bytes: usize,
    max_record_bytes: usize,
    byte_offset: u64,
    sequence: u64,
) PlanError!ChunkPlan {
    std.debug.assert(remaining > 0);
    std.debug.assert(remaining <= element_record_count);

    if (record_width == 0) {
        // Zero-width records: bounded logical progress, zero bytes, and
        // the byte offset is unchanged.
        const record_count = @min(remaining, zero_width_chunk_records);
        return .{
            .element_index = element_index,
            .first_record = first_record,
            .record_count = record_count,
            .element_record_count = element_record_count,
            .byte_count = 0,
            .byte_offset = byte_offset,
            .sequence = sequence,
        };
    }

    if (record_width > max_record_bytes) {
        return error.RecordTooLarge;
    }

    // How many records the preferred chunk size holds: at least one —
    // an oversized record still forms a complete single-record chunk.
    const target: u64 = @intCast(target_chunk_bytes);
    const width: u64 = @intCast(record_width);
    const capacity_records = target / width;
    const desired = @max(@as(u64, 1), capacity_records);

    const record_count = @min(remaining, desired);
    const byte_count = std.math.mul(u64, record_count, width) catch
        return error.SizeOverflow;

    return .{
        .element_index = element_index,
        .first_record = first_record,
        .record_count = record_count,
        .element_record_count = element_record_count,
        .byte_count = byte_count,
        .byte_offset = byte_offset,
        .sequence = sequence,
    };
}

/// Finalizes a plan against a real destination capacity: reduces the
/// record count so `byte_count` fits, requiring at least one record to
/// fit (a plan that cannot place a single record cannot be executed
/// against this buffer and must be reported, never silently reduced to
/// zero records). Zero-width plans pass through unchanged — they need
/// no capacity at all.
pub fn fitToCapacity(
    plan: ChunkPlan,
    available_capacity: usize,
) error{ InsufficientBufferCapacity, SizeOverflow }!ChunkPlan {
    if (plan.byte_count == 0) return plan;

    const capacity: u64 = @intCast(available_capacity);
    if (plan.byte_count <= capacity) return plan;

    const width = std.math.divTrunc(
        u64,
        plan.byte_count,
        plan.record_count,
    ) catch return error.SizeOverflow; // record_count > 0, cannot divide by zero

    const fitted = capacity / width;
    if (fitted == 0) return error.InsufficientBufferCapacity;

    var adjusted = plan;
    adjusted.record_count = fitted;
    adjusted.byte_count = std.math.mul(u64, fitted, width) catch
        return error.SizeOverflow;
    return adjusted;
}

// ---------------------------------------------------------------------------
// Tests (unit-level; reader-independent)
// ---------------------------------------------------------------------------

test "all remaining records fit when the target chunk is large" {
    const plan = try planChunk(0, 0, 1000, 1000, 24, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectEqual(@as(u64, 1000), plan.record_count);
    try std.testing.expectEqual(@as(u64, 1000 * 24), plan.byte_count);
}

test "the target chunk size rounds down to complete records" {
    // 4 MiB / 24 B = 174762 records exactly (4194288 bytes).
    const plan = try planChunk(0, 0, 1_000_000, 1_000_000, 24, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectEqual(@as(u64, 174762), plan.record_count);
    try std.testing.expectEqual(@as(u64, 4194288), plan.byte_count);

    // A target not divisible by the width also rounds down (4 MiB / 15 B).
    const plan15 = try planChunk(0, 0, 1_000_000, 1_000_000, 15, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectEqual(@as(u64, 279620), plan15.record_count);
    try std.testing.expectEqual(@as(u64, 279620 * 15), plan15.byte_count);
}

test "only one record remains: one final record" {
    const plan = try planChunk(0, 999, 1000, 1, 15, 4 * 1024 * 1024, 64 * 1024 * 1024, 1000 * 15, 41);
    try std.testing.expectEqual(@as(u64, 1), plan.record_count);
    try std.testing.expectEqual(@as(u64, 15), plan.byte_count);
    try std.testing.expectEqual(@as(u64, 999), plan.first_record);
}

test "an oversized record forms a single-record chunk when permitted" {
    // 6 MiB record > 4 MiB target: one complete record, no splitting.
    const width = 6 * 1024 * 1024;
    const plan = try planChunk(0, 0, 2, 2, width, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectEqual(@as(u64, 1), plan.record_count);
    try std.testing.expectEqual(@as(u64, width), plan.byte_count);
}

test "a record above the max record size limit is a resource error" {
    const width = 64 * 1024 * 1024 + 1;
    try std.testing.expectError(
        error.RecordTooLarge,
        planChunk(0, 0, 5, 5, width, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0),
    );
}

test "zero-width records make bounded logical progress without bytes" {
    // One million logical records: 65536-record chunks, zero bytes, and
    // the byte offset stays unchanged.
    const plan = try planChunk(0, 65536, 1_000_000, 1_000_000, 0, 4 * 1024 * 1024, 64 * 1024 * 1024, 777, 3);
    try std.testing.expectEqual(@as(u64, 65536), plan.record_count);
    try std.testing.expectEqual(@as(u64, 0), plan.byte_count);
    try std.testing.expectEqual(@as(u64, 777), plan.byte_offset);
    try std.testing.expectEqual(@as(u64, 65536), plan.first_record);

    // The tail chunk carries the remainder.
    const tail = try planChunk(0, 983040, 1_000_000, 17024, 0, 4 * 1024 * 1024, 64 * 1024 * 1024, 777, 15);
    try std.testing.expectEqual(@as(u64, 17024), tail.record_count);
    try std.testing.expectEqual(@as(u64, 0), tail.byte_count);
}

test "the planner never divides by zero for zero-width records" {
    _ = planChunk(0, 0, 1, 1, 0, 0, 64 * 1024 * 1024, 0, 0) catch |err| switch (err) {
        else => return err,
    };
}

test "fitToCapacity reduces the plan to what the buffer holds" {
    // Desired 174762 records × 24 B, but only 500 × 24 bytes fit.
    const desired = try planChunk(0, 0, 1_000_000, 1_000_000, 24, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    const fitted = try fitToCapacity(desired, 500 * 24);
    try std.testing.expectEqual(@as(u64, 500), fitted.record_count);
    try std.testing.expectEqual(@as(u64, 500 * 24), fitted.byte_count);
    try std.testing.expectEqual(desired.first_record, fitted.first_record);

    // Zero-width plans pass through regardless of capacity.
    const zero = try planChunk(0, 0, 100, 100, 0, 4096, 64 * 1024 * 1024, 0, 0);
    const zero_fitted = try fitToCapacity(zero, 0);
    try std.testing.expectEqual(zero.record_count, zero_fitted.record_count);

    // A single record that does not fit is an explicit error.
    const one = try planChunk(0, 0, 1, 1, 64, 4096, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectError(
        error.InsufficientBufferCapacity,
        fitToCapacity(one, 32),
    );
}

test "property-based: every successful plan is bounded and complete" {
    var prng = std.Random.DefaultPrng.init(0x51EA4E5B);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 512) : (trial += 1) {
        const width: usize = rand.intRangeAtMost(usize, 0, 4096);
        const remaining: u64 = rand.intRangeAtMost(u64, 1, 1 << 40);
        const target: usize = rand.intRangeAtMost(usize, 1, 32 * 1024 * 1024);
        const capacity: usize = rand.intRangeAtMost(usize, 0, 32 * 1024 * 1024);

        const desired = planChunk(
            0,
            0,
            remaining,
            remaining,
            width,
            target,
            64 * 1024 * 1024,
            0,
            0,
        ) catch |err| switch (err) {
            error.RecordTooLarge => {
                // Width over the limit: the only legal failure mode.
                try std.testing.expect(width > 64 * 1024 * 1024);
                continue;
            },
            error.SizeOverflow => unreachable, // inputs are far below overflow
        };

        try std.testing.expect(desired.record_count > 0);
        try std.testing.expect(desired.record_count <= remaining);

        if (width == 0) {
            try std.testing.expectEqual(@as(u64, 0), desired.byte_count);
        } else {
            const expected_bytes = std.math.mul(
                u64,
                desired.record_count,
                @intCast(width),
            ) catch unreachable;
            try std.testing.expectEqual(expected_bytes, desired.byte_count);
        }

        const fitted = try fitToCapacity(desired, capacity);
        try std.testing.expect(fitted.record_count > 0);
        try std.testing.expect(fitted.record_count <= desired.record_count);
        if (width > 0) {
            const fitted_bytes = std.math.mul(
                u64,
                fitted.record_count,
                @intCast(width),
            ) catch unreachable;
            try std.testing.expectEqual(fitted_bytes, fitted.byte_count);
            try std.testing.expect(fitted.byte_count <= capacity);
        }
    }
}
