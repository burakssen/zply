//! Inspect header metadata from a caller-owned reader.
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
    "1 2 3\n4 5 6\n7 8 9\n";

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed(source);
    var parser = try zply.Parser.init(init.gpa, threaded.io(), &reader, .{});
    defer parser.deinit();

    const header = parser.header();
    if (header.encoding != .ascii or header.elements.len != 1) return error.UnexpectedHeader;
    const vertex = header.elements[0];
    if (vertex.count != 3 or vertex.properties.len != 3) return error.UnexpectedHeader;

    std.debug.print("encoding={s} elements={d} vertex_records={d}\n", .{
        @tagName(header.encoding),
        header.elements.len,
        vertex.count,
    });
}
