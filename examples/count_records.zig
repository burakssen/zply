//! Stream batches without retaining decoded records.
const std = @import("std");
const zply = @import("zply");

const source =
    "ply\n" ++
    "format ascii 1.0\n" ++
    "element sample 4\n" ++
    "property int value\n" ++
    "end_header\n" ++
    "10\n20\n30\n40\n";

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(init.gpa, threaded.io(), &reader, .{ .chunk_size = 64 });
    defer parser.deinit();

    var count: u64 = 0;
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        count += batch.info().record_count;
    }
    if (count != 4) return error.UnexpectedRecordCount;
    std.debug.print("records={d}\n", .{count});
}
