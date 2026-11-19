//! Retrieve a detailed initialization diagnostic for malformed input.
const std = @import("std");
const zply = @import("zply");

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader: std.Io.Reader = .fixed("not-ply\n");
    var diagnostic: zply.Diagnostic = undefined;
    const result = zply.Parser.initDetailed(init.gpa, threaded.io(), &reader, .{}, &diagnostic);
    if (result) |parser_value| {
        var parser = parser_value;
        parser.deinit();
        return error.ExpectedInvalidHeader;
    } else |err| {
        if (err != error.InvalidMagic) return error.UnexpectedDiagnostic;
        const code = diagnostic.code orelse return error.MissingDiagnostic;
        if (code != error.InvalidMagic) return error.UnexpectedDiagnostic;
        std.debug.print("diagnostic={s} stage={s}\n", .{ @errorName(err), @tagName(diagnostic.stage) });
    }
}
