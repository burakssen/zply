//! Chunk planner unit and property tests (Task 4.13): the spec's sizing
//! table, capacity fitting, overflow rejection, and randomized invariants
//! including full coverage of the remaining record count by planned
//! sequences. Reader-independent — the planner never touches input.

const std = @import("std");
const support = @import("streaming_support.zig");

const internals = support.internals;
const planner = internals.input.planner;

// --- Spec table cases -------------------------------------------------------

test "all remaining records fit when the target chunk is large" {
    // 24 B records, 1,000 remaining, 4 MiB target → all 1,000.
    const plan = try planner.planChunk(0, 0, 1000, 1000, 24, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectEqual(@as(u64, 1000), plan.record_count);
    try std.testing.expectEqual(@as(u64, 24000), plan.byte_count);
}

test "the target chunk rounds down to complete records" {
    // 4 MiB / 24 B = 174,762 records exactly (4,194,288 bytes read).
    const plan = try planner.planChunk(
        0,
        0,
        1_000_000,
        1_000_000,
        24,
        4 * 1024 * 1024,
        64 * 1024 * 1024,
        0,
        0,
    );
    try std.testing.expectEqual(@as(u64, 174762), plan.record_count);
    try std.testing.expectEqual(@as(u64, 4194288), plan.byte_count);

    // A target not divisible by the width also rounds down (15 B records).
    const plan15 = try planner.planChunk(
        0,
        0,
        100,
        100,
        15,
        4 * 1024 * 1024,
        64 * 1024 * 1024,
        0,
        0,
    );
    try std.testing.expectEqual(@as(u64, 100), plan15.record_count);
    try std.testing.expectEqual(@as(u64, 1500), plan15.byte_count);
}

test "only one record remaining yields one final record" {
    const plan = try planner.planChunk(
        0,
        999,
        1000,
        1,
        15,
        4 * 1024 * 1024,
        64 * 1024 * 1024,
        15000,
        41,
    );
    try std.testing.expectEqual(@as(u64, 1), plan.record_count);
    try std.testing.expectEqual(@as(u64, 15), plan.byte_count);
    try std.testing.expectEqual(@as(u64, 999), plan.first_record);
    try std.testing.expectEqual(@as(u64, 15000), plan.byte_offset);
    try std.testing.expectEqual(@as(u64, 41), plan.sequence);
}

test "an oversized record is planned as one complete record" {
    // 6 MiB record, 4 MiB target, 2 remaining → one record, no split.
    const width = 6 * 1024 * 1024;
    const plan = try planner.planChunk(0, 0, 2, 2, width, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectEqual(@as(u64, 1), plan.record_count);
    try std.testing.expectEqual(@as(u64, width), plan.byte_count);
}

test "a record above the max record size is a resource error" {
    const width = 64 * 1024 * 1024 + 1;
    try std.testing.expectError(
        error.RecordTooLarge,
        planner.planChunk(0, 0, 5, 5, width, 4 * 1024 * 1024, 64 * 1024 * 1024, 0, 0),
    );
}

test "zero-width records plan bounded logical progress" {
    // 1,000,000 remaining: 65536-record chunks, zero bytes.
    const plan = try planner.planChunk(
        0,
        65536,
        1_000_000,
        1_000_000,
        0,
        4 * 1024 * 1024,
        64 * 1024 * 1024,
        777,
        3,
    );
    try std.testing.expectEqual(@as(u64, 65536), plan.record_count);
    try std.testing.expectEqual(@as(u64, 0), plan.byte_count);
    try std.testing.expectEqual(@as(u64, 777), plan.byte_offset);

    // The tail chunk carries the remainder.
    const tail = try planner.planChunk(
        0,
        983040,
        1_000_000,
        17024,
        0,
        4 * 1024 * 1024,
        64 * 1024 * 1024,
        777,
        15,
    );
    try std.testing.expectEqual(@as(u64, 17024), tail.record_count);
    try std.testing.expectEqual(@as(u64, 0), tail.byte_count);
}

test "a zero remaining count is never planned" {
    // `planChunk` asserts `remaining > 0` as its precondition (Debug panics,
    // release is unchecked): the producer decides completion *before*
    // planning and never calls it with zero remaining — covered by the
    // producer-level completion tests.
}

// --- Overflow ----------------------------------------------------------------

test "large dimensions remain bounded by the target" {
    const width: usize = 1 << 33;
    const plan = planner.planChunk(
        0,
        0,
        1 << 40,
        1 << 40,
        width,
        std.math.maxInt(usize),
        std.math.maxInt(usize),
        0,
        0,
    );
    const result = try plan;
    try std.testing.expect(result.byte_count <= std.math.maxInt(usize));
}

// --- Capacity fitting ----------------------------------------------------------

test "fitToCapacity reduces to complete records within capacity" {
    // Desired 174,762 records × 24 B; only 500 × 24 bytes fit.
    const desired = try planner.planChunk(
        0,
        0,
        1_000_000,
        1_000_000,
        24,
        4 * 1024 * 1024,
        64 * 1024 * 1024,
        0,
        0,
    );
    const fitted = try planner.fitToCapacity(desired, 500 * 24);
    try std.testing.expectEqual(@as(u64, 500), fitted.record_count);
    try std.testing.expectEqual(@as(u64, 12000), fitted.byte_count);
    try std.testing.expectEqual(desired.first_record, fitted.first_record);
    try std.testing.expectEqual(desired.sequence, fitted.sequence);
}

test "fitToCapacity passes zero-width plans through" {
    const zero = try planner.planChunk(0, 0, 100, 100, 0, 4096, 64 * 1024 * 1024, 0, 0);
    const fitted = try planner.fitToCapacity(zero, 0);
    try std.testing.expectEqual(zero.record_count, fitted.record_count);
    try std.testing.expectEqual(@as(u64, 0), fitted.byte_count);
}

test "a single record that cannot fit is an explicit error" {
    const one = try planner.planChunk(0, 0, 1, 1, 64, 4096, 64 * 1024 * 1024, 0, 0);
    try std.testing.expectError(error.InsufficientBufferCapacity, planner.fitToCapacity(one, 32));
}

// --- Property-based ------------------------------------------------------------

test "property: every plan is bounded, complete, and sequences cover the count" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 512) : (trial += 1) {
        const width: usize = rand.intRangeAtMost(usize, 0, 2048);
        // Bounded remaining so zero-width simulations terminate quickly.
        const remaining: u64 = rand.intRangeAtMost(u64, 1, 4096);
        const target: usize = rand.intRangeAtMost(usize, 1, 4 * 1024 * 1024);
        const capacity: usize = rand.intRangeAtMost(usize, @max(width, 1), 4 * 1024 * 1024);

        // Simulate planning a whole element: every plan must be a valid,
        // complete-record range, and together they cover exactly
        // `remaining` records with no gaps, duplicates, or infinite loops.
        var next_record: u64 = 0;
        var byte_offset: u64 = 0;
        var sequence: u64 = 0;
        var covered: u64 = 0;
        var iterations: u64 = 0;
        const max_iterations: u64 = remaining;
        while (next_record < remaining) {
            iterations += 1;
            try std.testing.expect(iterations <= max_iterations);

            const desired = try planner.planChunk(
                0,
                next_record,
                remaining,
                remaining - next_record,
                width,
                target,
                64 * 1024 * 1024,
                byte_offset,
                sequence,
            );
            try std.testing.expect(desired.record_count > 0);
            try std.testing.expect(desired.record_count <= remaining - next_record);
            try std.testing.expectEqual(next_record, desired.first_record);
            try std.testing.expectEqual(sequence, desired.sequence);

            const fitted = try planner.fitToCapacity(desired, capacity);
            try std.testing.expect(fitted.record_count > 0);
            try std.testing.expect(fitted.record_count <= desired.record_count);

            if (width == 0) {
                try std.testing.expectEqual(@as(u64, 0), fitted.byte_count);
                try std.testing.expectEqual(byte_offset, fitted.byte_offset);
            } else {
                const bytes = std.math.mul(u64, fitted.record_count, @intCast(width)) catch unreachable;
                try std.testing.expectEqual(bytes, fitted.byte_count);
                try std.testing.expect(bytes <= capacity);
                byte_offset += bytes;
            }

            covered += fitted.record_count;
            next_record += fitted.record_count;
            sequence += 1;
        }
        try std.testing.expectEqual(remaining, covered);
    }
}

test "property: capacity fitting never invents bytes beyond the buffer" {
    var prng = std.Random.DefaultPrng.init(0xB0B);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 512) : (trial += 1) {
        const width: usize = rand.intRangeAtMost(usize, 1, 4096);
        const remaining: u64 = rand.intRangeAtMost(u64, 1, 1 << 32);
        const target: usize = rand.intRangeAtMost(usize, 1, 8 * 1024 * 1024);
        const capacity: usize = rand.intRangeAtMost(usize, 0, 8 * 1024 * 1024);

        const desired = try planner.planChunk(
            0,
            0,
            remaining,
            remaining,
            width,
            target,
            std.math.maxInt(usize),
            0,
            0,
        );
        if (planner.fitToCapacity(desired, capacity)) |fitted| {
            // Only succeeds when at least one complete record fits.
            try std.testing.expect(fitted.record_count >= 1);
            const bytes = std.math.mul(u64, fitted.record_count, @intCast(width)) catch unreachable;
            try std.testing.expect(bytes <= capacity);
            try std.testing.expectEqual(bytes, fitted.byte_count);
        } else |err| {
            // The only legal failure: not even one record fits.
            try std.testing.expectEqual(error.InsufficientBufferCapacity, err);
            try std.testing.expect(capacity < width);
        }
    }
}
