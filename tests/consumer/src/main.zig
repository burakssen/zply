const std = @import("std");
const zply = @import("zply");

test "a standalone path dependency imports zply and streams typed columns" {
    const source =
        "ply\n" ++
        "format ascii 1.0\n" ++
        "element vertex 2\n" ++
        "property float x\n" ++
        "property float y\n" ++
        "property float z\n" ++
        "end_header\n" ++
        "1 2 3\n4 5 6\n";

    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(std.testing.allocator, threaded.io(), &reader, .{});
    defer parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), parser.header().elements.len);
    var records: usize = 0;
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        const x = try batch.typedColumn(f32, 0);
        const z = try batch.typedColumn(f32, 2);
        try std.testing.expectEqual(x.len, z.len);
        records += x.len;
    }
    try std.testing.expectEqual(@as(usize, 2), records);
}
