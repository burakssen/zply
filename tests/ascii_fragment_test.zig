//! Reader fragmentation must not influence ASCII token or record boundaries.
const std = @import("std");
const support = @import("streaming_support.zig");

test "ASCII scalar and list records survive one-byte reads and split CRLF" {
    const source = "ply\nformat ascii 1.0\nelement a 2\n" ++
        "property double x\nproperty list uchar ushort values\nend_header\n" ++
        "1.2345e-12 3 10 20 30\r\n" ++
        "-0.5 0\r\n";
    const pattern = [_]usize{ 1, 2, 1, 3, 1 };
    var fragmented = support.FragmentingReader.init(source, &pattern, 0);
    var parser = try support.Parser.init(std.testing.allocator, std.testing.io, fragmented.reader(), .{ .chunk_size = 16 });
    defer parser.deinit();
    var a = (try parser.next()).?;
    try std.testing.expectEqual(@as(f64, 1.2345e-12), (try a.typedColumn(f64, 0))[0]);
    try std.testing.expectEqualSlices(u16, &.{ 10, 20, 30 }, (try a.listColumn(1)).row(0).?.u16);
    a.release();
    var b = (try parser.next()).?;
    try std.testing.expectEqual(@as(f64, -0.5), (try b.typedColumn(f64, 0))[0]);
    try std.testing.expectEqual(@as(usize, 0), (try b.listColumn(1)).row(0).?.u16.len);
    b.release();
    try std.testing.expect((try parser.next()) == null);
}

test "ASCII unexpected extra value is rejected in fragmented reader" {
    const source = "ply\nformat ascii 1.0\nelement a 1\nproperty int x\nend_header\n1 2\n";
    const pattern = [_]usize{1};
    var fragmented = support.FragmentingReader.init(source, &pattern, 0);
    var parser = try support.Parser.init(std.testing.allocator, std.testing.io, fragmented.reader(), .{});
    defer parser.deinit();
    try std.testing.expectError(error.UnexpectedValue, parser.next());
}
