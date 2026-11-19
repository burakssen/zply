//! Read variable-length polygon indices through list offsets.
const std = @import("std");
const zply = @import("zply");

const source =
    "ply\n" ++
    "format ascii 1.0\n" ++
    "element face 3\n" ++
    "property list uchar int vertex_indices\n" ++
    "end_header\n" ++
    "3 0 1 2\n4 0 2 3 4\n0\n";

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(init.gpa, threaded.io(), &reader, .{});
    defer parser.deinit();

    var list_items: usize = 0;
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        const indices = try batch.listColumn(0);
        for (0..batch.info().record_count) |row| {
            const values = indices.row(row) orelse return error.InvalidListOffsets;
            switch (values) {
                .i32 => |items| list_items += items.len,
                else => return error.UnexpectedListType,
            }
        }
    }
    if (list_items != 7) return error.UnexpectedListCount;
    std.debug.print("face_index_items={d}\n", .{list_items});
}
