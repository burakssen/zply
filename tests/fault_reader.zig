//! Non-seekable std.Io.Reader double for Phase 11 M12 fault boundaries.
//! Delivers bounded fragments and injects an explicit EOF or I/O failure
//! after exactly `cutoff` source bytes have been passed to the reader.
//! Contains no parser imports, so it can be used from either test universe.
const std = @import("std");

pub const Fault = enum { none, eof, read_failed };

pub const Configuration = struct {
    /// Repeating nonzero limits on each underlying delivery.
    fragments: []const usize = &.{1},
    /// Failure takes effect before the first byte at this source offset.
    cutoff: ?usize = null,
    fault: Fault = .none,
};

const vtable: std.Io.Reader.VTable = .{ .stream = stream };

pub const FaultReader = struct {
    source: []const u8,
    config: Configuration,
    position: usize = 0,
    calls: usize = 0,
    fragment_index: usize = 0,
    fragment_remaining: usize = 0,
    scratch: [1]u8 = undefined,
    base: std.Io.Reader,

    pub fn init(source: []const u8, config: Configuration) FaultReader {
        std.debug.assert(config.fragments.len != 0);
        for (config.fragments) |len| std.debug.assert(len != 0);
        return .{
            .source = source,
            .config = config,
            .base = .{
                .vtable = &vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *FaultReader) *std.Io.Reader {
        self.base.buffer = &self.scratch;
        return &self.base;
    }
};

fn stream(base: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *FaultReader = @alignCast(@fieldParentPtr("base", base));
    self.calls += 1;

    if (self.config.cutoff) |at| {
        if (self.position >= at) switch (self.config.fault) {
            .none => {},
            .eof => return error.EndOfStream,
            .read_failed => return error.ReadFailed,
        };
    }
    if (self.position == self.source.len) return error.EndOfStream;

    if (self.fragment_remaining == 0) {
        self.fragment_remaining = self.config.fragments[self.fragment_index % self.config.fragments.len];
        self.fragment_index += 1;
    }
    var count = @min(@min(@backingInt(limit), self.fragment_remaining), self.source.len - self.position);
    if (self.config.cutoff) |at| {
        if (self.config.fault != .none) count = @min(count, at - self.position);
    }
    if (count == 0) return error.EndOfStream;

    const written = try writer.write(self.source[self.position..][0..count]);
    self.position += written;
    self.fragment_remaining -= written;
    return written;
}
