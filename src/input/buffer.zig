//! Reusable raw input storage: one bounded allocation, reused across
//! chunk reads.
//!
//! The producer reads each chunk into this buffer and hands the decoder
//! a borrowed slice of the valid prefix. One allocation serves many
//! chunks: capacity grows when a later element needs larger chunks and
//! never shrinks on smaller ones, avoiding allocation churn between
//! elements with different record widths.
//!
//! Capacity vs. length is the critical distinction: only
//! `[0, length)` is valid data. Unused capacity is never exposed — a
//! decoder must not be able to interpret uninitialized bytes.
//!
//! Ownership: the buffer owns its storage and releases it in `deinit`.
//! It never touches the reader, the allocator beyond its own storage, or
//! any other parser state. Phase 7 will transfer whole buffers between
//! tasks; the type is a plain value with no implicit sharing, so moving
//! ownership later needs no redesign.
//!
//! Phase 4 respects individual buffer limits (callers refuse
//! unreasonable `ensureCapacity` requests), but the authoritative global
//! memory budget arrives in Phase 6 — this buffer alone does not enforce
//! a total-memory limit.

const std = @import("std");

/// A growable, reusable raw input buffer.
pub const RawBuffer = struct {
    /// Backing allocation. `storage[0..length]` is valid data.
    storage: []u8 = &.{},
    /// Number of valid bytes currently in the buffer.
    length: usize = 0,
    /// The allocator that owns `storage`.
    allocator: std.mem.Allocator,

    /// Creates an empty buffer with no allocation. The first
    /// `ensureCapacity` performs the initial allocation — buffers are
    /// lazy so metadata-only parsers never pay for input storage.
    pub fn init(allocator: std.mem.Allocator) RawBuffer {
        return .{ .allocator = allocator };
    }

    /// Releases all storage. The buffer becomes empty and may be reused
    /// (it will allocate again on the next `ensureCapacity`).
    pub fn deinit(self: *RawBuffer) void {
        if (self.storage.len > 0) {
            self.allocator.free(self.storage);
        }
        self.storage = &.{};
        self.length = 0;
    }

    /// The total allocated capacity.
    pub fn capacity(self: *const RawBuffer) usize {
        return self.storage.len;
    }

    /// The valid, read-only prefix holding the last-read chunk.
    pub fn validData(self: *const RawBuffer) []const u8 {
        return self.storage[0..self.length];
    }

    /// A writable view of the whole capacity (callers write then set
    /// `length`).
    pub fn writable(self: *RawBuffer) []u8 {
        return self.storage;
    }

    /// Ensures capacity for `needed` bytes, growing only when the
    /// current capacity is insufficient. Never shrinks. Existing
    /// contents are preserved on growth (although the producer overwrites
    /// them on the next read, preservation keeps the buffer a
    /// conventional, safe container).
    pub fn ensureCapacity(self: *RawBuffer, needed: usize) error{OutOfMemory}!void {
        return self.ensureCapacityWithAllocator(needed, self.allocator);
    }

    /// Uses an operation-scoped allocator for growth. It must wrap the same
    /// underlying allocator and budget as the buffer's normal allocator.
    pub fn ensureCapacityWithAllocator(self: *RawBuffer, needed: usize, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        if (self.storage.len >= needed) return;
        self.storage = try allocator.realloc(self.storage, needed);
    }

    /// Marks `len` bytes (must be within capacity) as valid data.
    pub fn setLength(self: *RawBuffer, len: usize) void {
        std.debug.assert(len <= self.storage.len);
        self.length = len;
    }

    /// Clears the valid-data marker without freeing capacity, so the
    /// next chunk read reuses the same allocation.
    pub fn reset(self: *RawBuffer) void {
        self.length = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "an empty buffer allocates nothing until capacity is requested" {
    var buffer = RawBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 0), buffer.capacity());
    try std.testing.expectEqual(@as(usize, 0), buffer.validData().len);
}

test "capacity grows, never shrinks, and is reused across resets" {
    var buffer = RawBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    // First allocation for the initial chunk size.
    try buffer.ensureCapacity(300);
    const first_capacity = buffer.capacity();
    try std.testing.expect(first_capacity >= 300);

    // Fill the valid prefix; capacity beyond it is not exposed.
    @memset(buffer.writable()[0..240], 0xA5);
    buffer.setLength(240);
    try std.testing.expectEqual(@as(usize, 240), buffer.validData().len);
    try std.testing.expectEqual(@as(u8, 0xA5), buffer.validData()[0]);
    try std.testing.expectEqual(@as(u8, 0xA5), buffer.validData()[239]);

    // Reset reuses the same allocation.
    buffer.reset();
    try std.testing.expectEqual(first_capacity, buffer.capacity());
    try std.testing.expectEqual(@as(usize, 0), buffer.validData().len);

    // A larger chunk grows the capacity; a smaller one keeps it.
    try buffer.ensureCapacity(700);
    try std.testing.expect(buffer.capacity() >= 700);
    try buffer.ensureCapacity(100);
    try std.testing.expect(buffer.capacity() >= 700);
}

test "deinit releases storage and the buffer can be reused after" {
    var buffer = RawBuffer.init(std.testing.allocator);
    try buffer.ensureCapacity(128);
    buffer.setLength(16);
    buffer.deinit();

    try std.testing.expectEqual(@as(usize, 0), buffer.capacity());
    try std.testing.expectEqual(@as(usize, 0), buffer.length);

    // Reuse: allocates again.
    try buffer.ensureCapacity(64);
    try std.testing.expectEqual(@as(usize, 64), buffer.capacity());
    buffer.deinit();
}
