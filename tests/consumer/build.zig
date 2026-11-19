const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zply_dep = b.dependency("zply", .{
        .target = target,
        .optimize = optimize,
    });
    const consumer = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    consumer.addImport("zply", zply_dep.module("zply"));

    const tests = b.addTest(.{ .root_module = consumer });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the standalone zply consumer smoke test");
    test_step.dependOn(&run_tests.step);
}
