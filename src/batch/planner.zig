//! Checked output sizing, performed before allocating or reading body bytes.
const std = @import("std");
const layout_mod = @import("../format/layout.zig");
const input = @import("../input/planner.zig");

pub const BatchPlan = struct {
    element_index: usize,
    first_record: u64,
    record_count: usize,
    sequence: u64,
    raw_bytes_required: usize,
    decoded_bytes_required: usize,
};

pub fn plan(raw: input.ChunkPlan, layout: *const layout_mod.ElementLayout) error{ InvalidLayout, SizeOverflow }!BatchPlan {
    const n = std.math.cast(usize, raw.record_count) orelse return error.SizeOverflow;
    const bytes = std.math.cast(usize, raw.byte_count) orelse return error.SizeOverflow;
    const width = layout.fixed_record_size orelse return error.InvalidLayout;
    if (n == 0 or layout.element_index != raw.element_index) return error.InvalidLayout;
    if ((std.math.mul(usize, n, width) catch return error.SizeOverflow) != bytes) return error.InvalidLayout;
    var decoded_width: usize = 0;
    for (layout.properties) |property| {
        const t = property.scalar_type orelse return error.InvalidLayout;
        const w = property.fixed_width orelse return error.InvalidLayout;
        const offset = property.fixed_offset orelse return error.InvalidLayout;
        if (w != t.byteWidth() or offset > width or w > width - offset) return error.InvalidLayout;
        decoded_width = std.math.add(usize, decoded_width, w) catch return error.SizeOverflow;
    }
    return .{
        .element_index = raw.element_index,
        .first_record = raw.first_record,
        .record_count = n,
        .sequence = raw.sequence,
        .raw_bytes_required = bytes,
        .decoded_bytes_required = std.math.mul(usize, n, decoded_width) catch return error.SizeOverflow,
    };
}
