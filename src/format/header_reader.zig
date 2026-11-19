//! Bounded physical line reading for PLY headers.
//!
//! This module is deliberately independent of PLY directive syntax: it only
//! knows how to split a byte stream into newline-terminated lines while
//! enforcing byte limits *before* allocating, and while accounting exactly
//! how many bytes were consumed.
//!
//! Line conventions:
//!
//! * `\n` terminates a line (LF).
//! * `\r\n` terminates a line (CRLF); the `\r` is stripped from the returned
//!   line, but both terminator bytes are counted toward the consumed offset.
//! * A `\r` not followed by `\n` is an error (`InvalidLineEnding`), so a bare
//!   CR can never silently remain inside header content.
//! * Every header line — including `end_header` — must be newline-terminated.
//!   EOF in the middle of a line is `UnexpectedEndOfHeader`; clean EOF at a
//!   line boundary yields `null`.
//!
//! Reading is byte-wise (`Reader.takeByte`) rather than delimiter-oriented,
//! so correctness never depends on the caller's reader buffer being large
//! enough to hold a whole line. The reader's own buffering absorbs the
//! per-byte overhead.
//!
//! The reader does not own the stream. It owns only its reusable scratch
//! line buffer, allocated from the caller's allocator and freed by `deinit`.
//! Returned line slices point into the scratch buffer and are valid only
//! until the next `nextLine` call; the directive parser must copy anything
//! that must survive (it does).

const std = @import("std");
const errors = @import("../errors.zig");
const options_mod = @import("../options.zig");

const Options = options_mod.Options;

/// Errors produced while reading physical header lines. All of them are
/// members of `HeaderError`; this set exists so `nextLine`'s signature is
/// precise.
pub const LineError = error{
    /// The header exceeded `Limits.max_header_bytes` total.
    HeaderTooLarge,
    /// A single line exceeded `Limits.max_header_line_bytes`.
    HeaderLineTooLong,
    /// The input ended inside a line (no terminating newline).
    UnexpectedEndOfHeader,
    /// A `\r` was not followed by `\n`.
    InvalidLineEnding,
    /// The underlying reader failed. Distinguishable from every syntax
    /// error above.
    ReadFailed,
    /// The allocator refused the scratch buffer.
    OutOfMemory,
};

/// Bounded line reader over a borrowed `*std.Io.Reader`.
pub const HeaderLineReader = struct {
    /// Borrowed. Never seeked, reset, replaced, or closed.
    reader: *std.Io.Reader,

    /// Owns the scratch buffer only. Must outlive this reader.
    allocator: std.mem.Allocator,

    /// Reusable line scratch storage. Capacity grows to at most
    /// `max_line_bytes` (+ allocator rounding) over the header's lifetime.
    scratch: std.ArrayList(u8) = .empty,

    /// Total bytes consumed from the reader, including every terminator
    /// byte (both bytes of a CRLF). Relative to the reader's initial
    /// logical position.
    bytes_consumed: u64 = 0,

    /// Number of complete lines returned so far (1-based numbering).
    line_number: u64 = 0,

    /// Enforced before appending each content byte.
    max_header_bytes: usize,

    /// Enforced before appending each content byte.
    max_line_bytes: usize,

    /// Creates a reader with limits taken from `options`.
    pub fn init(
        reader: *std.Io.Reader,
        allocator: std.mem.Allocator,
        options: Options,
    ) HeaderLineReader {
        return .{
            .reader = reader,
            .allocator = allocator,
            .max_header_bytes = options.limits.max_header_bytes,
            .max_line_bytes = options.limits.max_header_line_bytes,
        };
    }

    /// Releases the scratch buffer. The underlying stream is untouched.
    pub fn deinit(self: *HeaderLineReader) void {
        self.scratch.deinit(self.allocator);
    }

    /// Returns the next header line without its terminator, or `null` at a
    /// clean EOF (i.e. at a line boundary).
    ///
    /// Limits are enforced incrementally:
    ///
    /// * The *total* header limit is checked after consuming each byte, so
    ///   a header of exactly `max_header_bytes` bytes is accepted and one
    ///   byte more is rejected (`HeaderTooLarge`).
    /// * The *line* limit is checked before appending each content byte, so
    ///   a line of exactly `max_line_bytes` content bytes is accepted.
    ///   Terminator bytes (and the `\r` of a CRLF, which is stripped) do not
    ///   count toward the line length.
    ///
    /// The returned slice points into reusable scratch storage and is
    /// invalidated by the next call.
    pub fn nextLine(self: *HeaderLineReader) LineError!?[]const u8 {
        self.scratch.clearRetainingCapacity();

        while (true) {
            const byte = self.reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    // EOF at a line boundary is a clean end; EOF inside a
                    // line means the header was not newline-terminated.
                    if (self.scratch.items.len == 0) return null;
                    return error.UnexpectedEndOfHeader;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            try self.accountByte();

            switch (byte) {
                '\n' => {
                    self.line_number += 1;
                    return self.scratch.items;
                },
                '\r' => {
                    // Peek-free CRLF handling: the next byte must be `\n`.
                    const next = self.reader.takeByte() catch |err| switch (err) {
                        error.EndOfStream => return error.UnexpectedEndOfHeader,
                        error.ReadFailed => return error.ReadFailed,
                    };
                    try self.accountByte();
                    if (next != '\n') return error.InvalidLineEnding;
                    self.line_number += 1;
                    return self.scratch.items;
                },
                else => {
                    // Enforce the line limit before allocating.
                    if (self.scratch.items.len >= self.max_line_bytes) {
                        return error.HeaderLineTooLong;
                    }
                    try self.scratch.append(self.allocator, byte);
                },
            }
        }
    }

    /// Accounts one consumed byte against the total header limit.
    fn accountByte(self: *HeaderLineReader) LineError!void {
        self.bytes_consumed += 1;
        if (self.bytes_consumed > self.max_header_bytes) {
            return error.HeaderTooLarge;
        }
    }
};
