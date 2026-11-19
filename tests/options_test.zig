//! Foundational tests for parser configuration (test group E).

const std = @import("std");
const ply = @import("zply");

test "default configuration is valid" {
    try (ply.Options{}).validate();
}

test "zero memory budget is invalid" {
    var options = ply.Options{};
    options.memory_budget = 0;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );
}

test "zero chunk size is invalid" {
    var options = ply.Options{};
    options.chunk_size = 0;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );
}

test "chunk size larger than memory budget is invalid" {
    var options = ply.Options{};
    options.chunk_size = options.memory_budget + 1;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );
}

test "chunk size is not required to divide the budget evenly" {
    var options = ply.Options{};
    options.memory_budget = 1024 * 1024;
    options.chunk_size = 100 * 1024 + 37;
    try options.validate();
}

test "zero maximum header bytes is invalid" {
    var options = ply.Options{};
    options.limits.max_header_bytes = 0;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );
}

test "max header line bytes greater than max header bytes is invalid" {
    var options = ply.Options{};
    options.limits.max_header_line_bytes = options.limits.max_header_bytes + 1;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );
    // Equal is fine.
    options.limits.max_header_line_bytes = options.limits.max_header_bytes;
    try options.validate();
}

test "invalid resource-limit relationships are rejected" {
    // Per-element property cap above the total property cap.
    var options = ply.Options{};
    options.limits.max_properties_per_element =
        options.limits.max_total_properties + 1;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );

    // Each individual limit must be nonzero.
    const limit_fields = @typeInfo(ply.Limits).@"struct".field_names;
    inline for (limit_fields) |field_name| {
        var o = ply.Options{};
        @field(o.limits, field_name) = 0;
        try std.testing.expectError(
            error.InvalidConfiguration,
            o.validate(),
        );
    }
}

test "max record bytes below the widest scalar is invalid" {
    var options = ply.Options{};
    options.limits.max_record_bytes = ply.ScalarType.max_width - 1;
    try std.testing.expectError(
        error.InvalidConfiguration,
        options.validate(),
    );
    options.limits.max_record_bytes = ply.ScalarType.max_width;
    try options.validate();
}

test "small valid configuration is accepted" {
    const options = ply.Options{
        .memory_budget = 1 * 1024 * 1024,
        .chunk_size = 16 * 1024,
        .preserve_order = false,
        .strict = false,
        .limits = .{
            .max_header_bytes = 64 * 1024,
            .max_header_line_bytes = 4 * 1024,
            .max_elements = 8,
            .max_properties_per_element = 16,
            .max_total_properties = 64,
            .max_record_bytes = 4096,
        },
    };
    try options.validate();
}

test "public contract preserves: no thread-count configuration fields" {
    // The configuration must not expose workers/threads/parallelism knobs;
    // execution is owned by the supplied std.Io implementation.
    const option_fields = @typeInfo(ply.Options).@"struct".field_names;
    for (option_fields) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "workers"));
        try std.testing.expect(!std.mem.eql(u8, name, "threads"));
        try std.testing.expect(!std.mem.startsWith(u8, name, "max_parallel"));
    }

    const limit_fields = @typeInfo(ply.Limits).@"struct".field_names;
    for (limit_fields) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "workers"));
        try std.testing.expect(!std.mem.eql(u8, name, "threads"));
    }
}

test "validation is pure: defaults validate repeatedly without state" {
    const options = ply.Options{};
    try options.validate();
    try options.validate();
    try options.validate();
}
