//! Fault-injecting std.Io.Reader test double, independent of parser modules.
//! This can be used by either public-API or internal-only test suites
//! without causing Zig to assign parser source files to two modules.
const std = @import("std");

const failing_vtable = std.Io.Reader.VTable{
    .stream = failingStream,
};

/// A reader that delivers bytes normally until a configured point, then
/// fails with `error.ReadFailed`. `fail_after == null` fails on the first
/// read; a byte count fails after that many delivered bytes — modeling both
/// "reader fails before delivering a chunk" and "fails after earlier
/// successful chunks".
pub const FailingReader = struct {
    source: []const u8,
    position: usize = 0,
    fail_after: ?usize,
    buffer: [1]u8 = undefined,
    base: std.Io.Reader,

    pub fn init(source: []const u8, fail_after: ?usize) FailingReader {
        return .{
            .source = source,
            .fail_after = fail_after,
            .base = .{
                .vtable = &failing_vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *FailingReader) *std.Io.Reader {
        self.base.buffer = &self.buffer;
        return &self.base;
    }
};

fn failingDeliver(self: *FailingReader, want: usize) std.Io.Reader.Error!usize {
    if (self.fail_after) |budget| {
        if (self.position >= budget) return error.ReadFailed;
    }
    const source_remaining = self.source.len - self.position;
    if (source_remaining == 0) return error.EndOfStream;
    var n = @min(want, source_remaining);
    if (self.fail_after) |budget| {
        n = @min(n, budget - self.position);
    }
    return n;
}

fn failingStream(
    base: *std.Io.Reader,
    w: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const self: *FailingReader = @alignCast(@fieldParentPtr("base", base));
    const n = try failingDeliver(self, @backingInt(limit));
    const written = try w.write(self.source[self.position..][0..n]);
    self.position += written;
    return written;
}

fn failingReadVec(
    base: *std.Io.Reader,
    data: [][]u8,
) std.Io.Reader.Error!usize {
    const self: *FailingReader = @alignCast(@fieldParentPtr("base", base));
    var total: usize = 0;
    for (data) |dest| {
        if (dest.len == 0) continue;
        const n = try failingDeliver(self, dest.len);
        @memcpy(dest[0..n], self.source[self.position..][0..n]);
        self.position += n;
        total += n;
        if (n < dest.len) break;
    }
    return total;
}

fn failingRebase(
    base: *std.Io.Reader,
    capacity: usize,
) std.Io.Reader.RebaseError!void {
    _ = base;
    _ = capacity;
}
