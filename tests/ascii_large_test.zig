//! Opt-in Phase 8 scale validation; run with:
//!   zig build test-ascii-large -Doptimize=ReleaseFast
//!
//! These tests use a virtual source so even the multi-million-record inputs
//! need no large fixture allocation. They validate every decoded record.
const std = @import("std");
const dataset = @import("ascii_dataset_support.zig");

test "3M ASCII XYZ f32 records" {
    try dataset.run(std.testing.allocator, std.testing.io, .xyz_f32, 3_000_000);
}
test "3M ASCII XYZ f64 records" {
    try dataset.run(std.testing.allocator, std.testing.io, .xyz_f64, 3_000_000);
}
test "3M ASCII XYZRGB mixed scalar records" {
    try dataset.run(std.testing.allocator, std.testing.io, .xyzrgb, 3_000_000);
}
test "1M ASCII wide custom records" {
    try dataset.run(std.testing.allocator, std.testing.io, .wide, 1_000_000);
}
test "1M ASCII triangle list records" {
    try dataset.run(std.testing.allocator, std.testing.io, .triangles, 1_000_000);
}
test "100K ASCII mixed polygon list records" {
    try dataset.run(std.testing.allocator, std.testing.io, .polygons, 100_000);
}
test "3M ASCII zero-property records" {
    try dataset.run(std.testing.allocator, std.testing.io, .empty, 3_000_000);
}

// Distinct record contents ensure the scale test catches replays or stale
// batches even if the total record count and sequence metadata look correct.
test "3M ASCII unique record IDs, signed values, and buckets" {
    try dataset.run(std.testing.allocator, std.testing.io, .sequence, 3_000_000);
}
