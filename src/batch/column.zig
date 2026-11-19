//! Read-only typed column views.
const types = @import("../format/types.zig");

pub const ScalarColumn = union(types.ScalarType) {
    i8: []const i8,
    u8: []const u8,
    i16: []const i16,
    u16: []const u16,
    i32: []const i32,
    u32: []const u32,
    f32: []const f32,
    f64: []const f64,

    pub fn scalarType(self: ScalarColumn) types.ScalarType {
        return self;
    }
    pub fn len(self: ScalarColumn) usize {
        return switch (self) {
            inline else => |values| values.len,
        };
    }
};

/// A variable-length property: one offset pair per record, and typed items.
pub const ListColumn = struct {
    offsets: []const usize,
    values: ScalarColumn,

    pub fn row(self: ListColumn, i: usize) ?ScalarColumn {
        // Check without adding one to an arbitrary caller-provided index:
        // maxInt(usize) must return null, not overflow in safe builds.
        if (self.offsets.len < 2 or i >= self.offsets.len - 1) return null;
        const a = self.offsets[i];
        const b = self.offsets[i + 1];
        if (a > b or b > self.values.len()) return null;
        return switch (self.values) {
            inline else => |items, tag| @unionInit(ScalarColumn, @tagName(tag), items[a..b]),
        };
    }
};

pub const Column = struct {
    property_index: usize,
    /// Scalar value for ordinary properties; for list properties use `list`.
    /// Kept for backwards compatibility with the Phase 7 scalar API.
    values: ScalarColumn,
    list: ?ListColumn = null,
};
