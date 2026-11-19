//! Configure a parser-managed memory budget and inspect its peak usage.
const std = @import("std");
const zply = @import("zply");

const source =
    "ply\n" ++
    "format ascii 1.0\n" ++
    "element sample 3\n" ++
    "property float value\n" ++
    "end_header\n" ++
    "1\n2\n3\n";

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(init.gpa, threaded.io(), &reader, .{
        .memory_budget = 64 * 1024,
        .chunk_size = 1024,
    });
    defer parser.deinit();

    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        batch.release();
    }
    const stats = parser.memoryStats();
    if (stats.peak_total_bytes > 64 * 1024) return error.MemoryBudgetExceeded;
    std.debug.print("parser_peak_bytes={d}\n", .{stats.peak_total_bytes});
}
