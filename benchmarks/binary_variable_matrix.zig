//! Opt-in Phase 10 configuration matrix, reusing the same validated fixture
//! generation and checksum as the baseline binary-variable benchmark.
const std = @import("std");
const suite = @import("binary_variable_pipeline.zig");

pub fn main(init: std.process.Init) !void {
    try suite.runMatrix(init);
}
