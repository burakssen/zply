//! Phase 11 M2: unified, allocation-free diagnostics for init and streaming.
//! This suite deliberately uses only the public module.
const std = @import("std");
const ply = @import("zply");

fn noError(diagnostic: ply.Diagnostic) !void {
    try std.testing.expect(diagnostic.code == null);
}

test "initDetailed preserves the exact error, header line and directive" {
    const prefix = "ply\nformat ascii 1.0\nelement vertex 1\n";
    const bytes = prefix ++ "property float\nend_header\n";
    var reader: std.Io.Reader = .fixed(bytes);
    var diagnostic: ply.Diagnostic = .{ .category = .record };

    try std.testing.expectError(error.InvalidProperty, ply.Parser.initDetailed(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
        &diagnostic,
    ));
    try std.testing.expect(diagnostic.code.? == error.InvalidProperty);
    try std.testing.expectEqual(ply.Diagnostic.Stage.header, diagnostic.stage);
    try std.testing.expectEqual(ply.Diagnostic.Category.header, diagnostic.category);
    try std.testing.expectEqual(@as(u64, 4), diagnostic.line_number.?);
    try std.testing.expectEqual(ply.Diagnostic.Directive.property, diagnostic.directive.?);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.element_index.?);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.property_index.?);
    try std.testing.expectEqual(@as(u64, prefix.len), diagnostic.byte_offset.?);
    try std.testing.expectEqual(@as(u64, prefix.len + "property float\n".len), diagnostic.failure_byte_offset.?);
}

test "initDetailed reports configuration before consuming any reader input" {
    const bytes = "ply\nformat ascii 1.0\nend_header\n";
    var reader: std.Io.Reader = .fixed(bytes);
    var diagnostic: ply.Diagnostic = .{ .category = .record };
    try std.testing.expectError(error.InvalidConfiguration, ply.Parser.initDetailed(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{ .chunk_size = 0 },
        &diagnostic,
    ));
    try std.testing.expectEqual(ply.Diagnostic.Category.configuration, diagnostic.category);
    try std.testing.expectEqual(ply.Diagnostic.Stage.configuration, diagnostic.stage);
    try std.testing.expect(diagnostic.code.? == error.InvalidConfiguration);
    try std.testing.expect(diagnostic.byte_offset == null);
    try std.testing.expectEqual(@as(u8, 'p'), try reader.takeByte());
}

test "initDetailed clears the output on successful initialization" {
    const bytes = "ply\nformat ascii 1.0\nend_header\nEXTRA";
    var reader: std.Io.Reader = .fixed(bytes);
    var diagnostic: ply.Diagnostic = .{ .category = .record, .code = error.InvalidMagic };
    var parser = try ply.Parser.initDetailed(std.testing.allocator, std.testing.io, &reader, .{}, &diagnostic);
    defer parser.deinit();
    try noError(diagnostic);
    try std.testing.expect(parser.lastDiagnostic() == null);
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expect(parser.lastDiagnostic() == null);
    try std.testing.expectEqual(@as(u8, 'E'), try reader.takeByte());
}

test "lastDiagnostic captures the exact ASCII error and is a stable value" {
    const bytes = "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nend_header\n" ++
        "not-a-number\n";
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{ .chunk_size = 64 });
    defer parser.deinit();
    try std.testing.expectError(error.InvalidNumber, parser.next());
    const snapshot = parser.lastDiagnostic().?;
    try std.testing.expect(snapshot.code.? == error.InvalidNumber);
    try std.testing.expectEqual(ply.Diagnostic.Category.record, snapshot.category);
    try std.testing.expectEqual(@as(u64, 0), snapshot.element_index.?);
    try std.testing.expectEqual(@as(u64, 0), snapshot.record_index.?);
    try std.testing.expectEqual(@as(u64, 0), snapshot.property_index.?);
    try std.testing.expect(snapshot.line_number != null);
    try std.testing.expectEqual(snapshot.byte_offset.?, parser.asciiDiagnostic().?.byte_offset.?);
    try std.testing.expect(snapshot.token_byte_offset != null);
}

test "lastDiagnostic preserves binary-list truncation location" {
    const header = "ply\nformat binary_little_endian 1.0\nelement face 1\n" ++
        "property list ushort int vertex_indices\nend_header\n";
    // 3 declared i32 items, but only the first value is present.
    const bytes = header ++ "\x03\x00\x2A\x00\x00\x00";
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{
        .chunk_size = 64,
        .memory_budget = 2 * 1024 * 1024,
    });
    defer parser.deinit();
    try std.testing.expectError(error.TruncatedListPayload, parser.next());
    const snapshot = parser.lastDiagnostic().?;
    try std.testing.expect(snapshot.code.? == error.TruncatedListPayload);
    try std.testing.expectEqual(ply.Diagnostic.Category.truncation, snapshot.category);
    try std.testing.expectEqual(@as(u64, 0), snapshot.record_index.?);
    try std.testing.expectEqual(@as(u64, 0), snapshot.property_index.?);
    try std.testing.expectEqual(@as(u64, header.len), snapshot.byte_offset.?);
}
