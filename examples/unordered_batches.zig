//! Consume batches without assuming completion order.
const std = @import("std");
const zply = @import("zply");

const source =
    "ply\n" ++
    "format binary_little_endian 1.0\n" ++
    "element sample 4\n" ++
    "property uint value\n" ++
    "end_header\n" ++
    "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00";

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .limited(2) });
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(init.gpa, threaded.io(), &reader, .{
        .preserve_order = false,
        .chunk_size = 64,
    });
    defer parser.deinit();

    var records: u64 = 0;
    var previous_sequence: ?u64 = null;
    while (try parser.next()) |batch_value| {
        var batch = batch_value;
        defer batch.release();
        const info = batch.info();
        if (previous_sequence) |previous| {
            // Sequence identity is metadata, not a signal that batches were
            // delivered in source order.
            if (info.sequence == previous) return error.DuplicateSequence;
        }
        previous_sequence = info.sequence;
        records += info.record_count;
    }
    if (records != 4) return error.UnexpectedRecordCount;
    std.debug.print("records={d} (completion order is permitted)\n", .{records});
}
