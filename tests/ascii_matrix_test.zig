//! Fast CI coverage for every Phase 8 dataset family.
const std = @import("std");
const dataset = @import("ascii_dataset_support.zig");

test "ASCII f32 and f64 XYZ streams preserve every typed value" {
    try dataset.run(std.testing.allocator, std.testing.io, .xyz_f32, 4097);
    try dataset.run(std.testing.allocator, std.testing.io, .xyz_f64, 4097);
}

test "ASCII mixed type and wide schemas preserve property declaration order" {
    try dataset.run(std.testing.allocator, std.testing.io, .xyzrgb, 4097);
    try dataset.run(std.testing.allocator, std.testing.io, .wide, 4097);
}

test "ASCII triangle and variable polygon lists preserve offset and value invariants" {
    try dataset.run(std.testing.allocator, std.testing.io, .triangles, 1025);
    try dataset.run(std.testing.allocator, std.testing.io, .polygons, 1025);
}

test "ASCII zero-property streams make progress without storing per-record payload" {
    try dataset.run(std.testing.allocator, std.testing.io, .empty, 8193);
}

// Catch duplicate, skipped, or stale data that periodic four-row fixtures
// cannot detect, including around chunk and reader-buffer boundaries.
test "ASCII unique record IDs remain correct across many batches" {
    try dataset.run(std.testing.allocator, std.testing.io, .sequence, 8193);
}
