//! Executed as a separate process by `zig build test`.
//! The custom panic handler turns only the expected panic message into exit
//! code 86; setup errors, unrelated panics and missing panics cannot pass.
const std = @import("std");
const ply = @import("zply");

var expected_panic: []const u8 = "";

pub const panic = std.debug.FullPanic(handlePanic);
fn handlePanic(message: []const u8, _: ?usize) noreturn {
    if (std.mem.eql(u8, message, expected_panic)) std.process.exit(86);
    std.process.exit(87);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    const mode = args[1];
    const source = "ply\nformat binary_little_endian 1.0\n" ++
        "element item 2\nproperty uchar value\nend_header\n" ++ [_]u8{ 1, 2 };
    var reader: std.Io.Reader = .fixed(source);
    var options: ply.Options = .{};
    options.chunk_size = 1;
    var parser = try ply.Parser.init(init.gpa, init.io, &reader, options);
    var batch = (try parser.next()) orelse return error.MissingBatch;

    if (std.mem.eql(u8, mode, "active-deinit")) {
        expected_panic = "batch lease still active during parser destruction";
        parser.deinit();
        return;
    }
    var copied = batch;
    batch.release();
    var reused = (try parser.next()) orelse return error.MissingBatch;
    if (std.mem.eql(u8, mode, "stale-release")) {
        expected_panic = "invalid or released batch lease";
        copied.release();
        return;
    }
    if (std.mem.eql(u8, mode, "stale-access")) {
        expected_panic = "invalid or released batch lease";
        _ = copied.info();
        return;
    }
    if (!std.mem.eql(u8, mode, "control")) return error.InvalidArguments;
    if (copied.isValid() or !reused.isValid()) return error.InvalidLeaseState;
    reused.release();
    parser.deinit();
}
