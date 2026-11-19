//! Read f32 coordinate columns and calculate point-cloud bounds.
const std = @import("std");
const zply = @import("zply");

const source =
    "ply\n" ++
    "format ascii 1.0\n" ++
    "element vertex 3\n" ++
    "property float x\n" ++
    "property float y\n" ++
    "property float z\n" ++
    "end_header\n" ++
    "1 2 3\n-4 5 6\n7 -8 9\n";

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(init.gpa, threaded.io(), &reader, .{});
    defer parser.deinit();

    var min = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var max = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        const x = try batch.typedColumn(f32, 0);
        const y = try batch.typedColumn(f32, 1);
        const z = try batch.typedColumn(f32, 2);
        for (x, y, z) |px, py, pz| {
            min[0] = @min(min[0], px);
            min[1] = @min(min[1], py);
            min[2] = @min(min[2], pz);
            max[0] = @max(max[0], px);
            max[1] = @max(max[1], py);
            max[2] = @max(max[2], pz);
        }
    }
    if (!std.mem.eql(f32, &min, &.{ -4, -8, 3 }) or !std.mem.eql(f32, &max, &.{ 7, 5, 9 }))
        return error.UnexpectedBounds;
    std.debug.print("min=({d}, {d}, {d}) max=({d}, {d}, {d})\n", .{
        min[0], min[1], min[2], max[0], max[1], max[2],
    });
}
