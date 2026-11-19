//! Phase 11 M4: taxonomy is stable, allocation-free, and explicitly advisory
//! about retryability. Only the public module is used.
const std = @import("std");
const ply = @import("zply");
const D = ply.Diagnostic;

test "header arithmetic overflow is not classified as a body record failure" {
    try std.testing.expectEqual(D.Category.header, D.categoryFor(error.NumericOverflow));
    try std.testing.expectEqual(D.Stage.header, D.stageFor(error.NumericOverflow));
    const d = D.fromError(error.NumericOverflow, .header);
    try std.testing.expect(d.code.? == error.NumericOverflow);
    try std.testing.expectEqual(D.Category.header, d.category);
    try std.testing.expectEqual(D.Recovery.terminal, d.recovery);
}

test "error taxonomy distinguishes malformed, unsupported, resource and I/O failures" {
    try std.testing.expectEqual(D.Category.scalar_type, D.categoryFor(error.InvalidScalarType));
    try std.testing.expectEqual(D.Category.version, D.categoryFor(error.UnsupportedVersion));
    try std.testing.expectEqual(D.Category.record, D.categoryFor(error.InvalidNumber));
    try std.testing.expectEqual(D.Category.truncation, D.categoryFor(error.TruncatedListPayload));
    try std.testing.expectEqual(D.Category.truncation, D.categoryFor(error.TruncatedBody));
    try std.testing.expectEqual(D.Category.resource_limit, D.categoryFor(error.RecordTooLarge));
    try std.testing.expectEqual(D.Category.reader, D.categoryFor(error.ReadFailed));
    try std.testing.expectEqual(D.Category.execution, D.categoryFor(error.InvalidProducerState));
    try std.testing.expectEqual(D.Category.memory, D.categoryFor(error.MemoryPressure));
}

test "recovery guidance distinguishes pressure, contextual errors and terminal errors" {
    try std.testing.expectEqual(D.Recovery.resource_pressure, D.recoveryFor(error.MemoryPressure));
    try std.testing.expectEqual(D.Recovery.resource_pressure, D.recoveryFor(error.BatchCapacityUnavailable));
    try std.testing.expectEqual(D.Recovery.context_dependent, D.recoveryFor(error.ResourceLimitExceeded));
    try std.testing.expectEqual(D.Recovery.context_dependent, D.recoveryFor(error.OutOfMemory));
    try std.testing.expectEqual(D.Recovery.terminal, D.recoveryFor(error.TruncatedRecord));
    try std.testing.expectEqual(D.Recovery.terminal, D.recoveryFor(error.ReadFailed));
    try std.testing.expectEqual(D.Recovery.terminal, D.recoveryFor(error.InvalidConfiguration));
    try std.testing.expectEqual(D.Recovery.terminal, D.recoveryFor(error.InvalidProducerState));
    const pressure = D.fromError(error.MemoryPressure, .memory);
    try std.testing.expectEqual(D.Recovery.resource_pressure, pressure.recovery);
    try std.testing.expectEqual(D.Stage.memory, pressure.stage);
}

test "initDetailed uses the same recovery classification for malformed headers" {
    var reader: std.Io.Reader = .fixed("not_ply\n");
    var diagnostic: D = .{ .category = .record };
    try std.testing.expectError(error.InvalidMagic, ply.Parser.initDetailed(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
        &diagnostic,
    ));
    try std.testing.expectEqual(D.Category.header, diagnostic.category);
    try std.testing.expectEqual(D.Stage.header, diagnostic.stage);
    try std.testing.expectEqual(D.Recovery.terminal, diagnostic.recovery);
}

test "streaming diagnostic keeps parser error and taxonomy after malformed number" {
    const bytes = "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nend_header\nnot-a-number\n";
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try ply.Parser.init(std.testing.allocator, std.testing.io, &reader, .{});
    defer parser.deinit();
    try std.testing.expectError(error.InvalidNumber, parser.next());
    const diagnostic = parser.lastDiagnostic().?;
    try std.testing.expect(diagnostic.code.? == error.InvalidNumber);
    try std.testing.expectEqual(D.Recovery.terminal, diagnostic.recovery);
    try std.testing.expectEqual(D.Category.record, diagnostic.category);
}
