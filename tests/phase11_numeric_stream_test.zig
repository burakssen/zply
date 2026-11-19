//! Phase 11 M5: public Parser.next() exposes numeric errors, never partial output.
const std = @import("std");
const ply = @import("zply");

test "M5 streaming integer overflow returns a stable diagnostic" {
    var reader: std.Io.Reader = .fixed(
        "ply\nformat ascii 1.0\nelement vertex 2\nproperty uchar flag\nend_header\n" ++
            "1\n256\n",
    );
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 1024 });
    defer parser.deinit();
    try std.testing.expectError(error.IntegerOverflow, parser.next());
    const diagnostic = parser.lastDiagnostic().?;
    try std.testing.expect(diagnostic.code.? == error.IntegerOverflow);
    try std.testing.expectEqual(@as(?u64, 1), diagnostic.record_index);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.property_index);
    try std.testing.expectError(error.InvalidProducerState, parser.next());
}

test "M5 streaming floats retain signed zero and accepted special values" {
    var reader: std.Io.Reader = .fixed(
        "ply\nformat ascii 1.0\nelement vertex 3\nproperty float a\nproperty double b\nend_header\n" ++
            "-0 -0.0\ninf -inf\nnan 1.25e2\n",
    );
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 1024 });
    defer parser.deinit();
    var batch = (try parser.next()).?;
    defer batch.release();
    const f32_values = try batch.typedColumn(f32, 0);
    const f64_values = try batch.typedColumn(f64, 1);
    try std.testing.expectEqual(@as(usize, 3), f32_values.len);
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(f32_values[0])));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(f64_values[0])));
    try std.testing.expect(std.math.isInf(f32_values[1]));
    try std.testing.expect(f64_values[1] < 0);
    try std.testing.expect(std.math.isNan(f32_values[2]));
    try std.testing.expectEqual(@as(f64, 125), f64_values[2]);
    try std.testing.expect((try parser.next()) == null);
}
