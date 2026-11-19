//! Compiled record layouts derived from a validated header.
//!
//! The header parser compiles every element's properties into offsets and
//! widths once, at initialization, so later phases never reinterpret the
//! schema inside a per-record loop.
//!
//! Two distinct questions are answered here, and they are not the same:
//!
//! 1. Is a *property* fixed-width? (A scalar is; a list never is.)
//! 2. Is a property's *byte position* fixed? (Only while no preceding
//!    property is variable-length.)
//!
//! For `property float confidence`, `property list uchar int neighbors`,
//! `property double timestamp`:
//!
//!   confidence  fixed_offset 0    fixed_width 4
//!   neighbors   fixed_offset 4    fixed_width null  (the count prefix
//!                 starts at a fixed position; the payload does not)
//!   timestamp   fixed_offset null fixed_width 8
//!
//! The element's `fixed_record_size` is `null` and its
//! `minimum_record_size` is 4 + 1 + 8 = 13 (the `uchar` list count always
//! contributes one byte; list items add more).
//!
//! Element body positions chain the same way: a *fixed-width* element's
//! total body size is known (`count × record size`, computed with checked
//! arithmetic), so the following element's `body_start_offset` is known.
//! Once an element with variable-width records is seen, all later
//! `body_start_offset` values remain unresolved (`null`) until the
//! variable-length body has actually been scanned — the header alone cannot
//! know them.
//!
//! This module performs no I/O and touches no reader; it works entirely
//! from validated schema objects.

const std = @import("std");
const errors = @import("../errors.zig");
const header_mod = @import("header.zig");
const types = @import("types.zig");

const Header = header_mod.Header;
const HeaderError = errors.HeaderError;

/// Binary structural operation compiled once from a validated property.
/// The scanner does not need to consult property names or header strings.
pub const BinaryPropertyOp = union(enum) {
    scalar: struct {
        scalar_type: types.ScalarType,
        width: usize,
    },
    list: struct {
        count_type: types.IntegerType,
        count_width: usize,
        item_type: types.ScalarType,
        item_width: usize,
    },
};

/// Compiled layout of one property within its element.
pub const PropertyLayout = struct {
    /// Index of the property within its element, in declaration order.
    property_index: usize,

    /// Byte offset of the property's first byte within a record. Known only
    /// when no preceding variable-width property affects this position;
    /// `null` otherwise. For a list property this is the offset of the
    /// count prefix.
    fixed_offset: ?usize,

    /// Fixed byte width per record, or `null` for a variable-length list
    /// (whose payload depends on the runtime count).
    fixed_width: ?usize,

    /// The declared scalar type for a scalar property (`null` for a list).
    /// Decoding uses this instead of re-resolving property type names.
    scalar_type: ?types.ScalarType,

    /// Structural instruction for Phase 10's binary variable-record scanner.
    /// Null only for hand-built legacy layouts which did not supply it;
    /// `compileSchema` always fills it. Such layouts are rejected by the
    /// variable-record scanner rather than guessed from incomplete metadata.
    binary_op: ?BinaryPropertyOp = null,
};

/// Compiled layout of one element.
pub const ElementLayout = struct {
    /// Index of the element in header order.
    element_index: usize,

    /// Per-record byte size when every property is fixed-width, or `null`
    /// when records contain lists. Zero properties yields `0` (a real
    /// width): such records carry no payload but still advance the record
    /// index.
    fixed_record_size: ?usize,

    /// Minimum bytes any one record can occupy: the sum of all scalar
    /// widths plus every list's count-prefix width. Equal to
    /// `fixed_record_size` when the element is fixed-width.
    minimum_record_size: usize,

    /// Offset of this element's first byte, relative to the start of the
    /// body (i.e. relative to the first byte after `end_header`). `null`
    /// when any earlier element has variable-width records.
    body_start_offset: ?u64,

    /// Total body size when the element is fixed-width, or `null` when the
    /// body size depends on runtime list lengths.
    fixed_body_size: ?u64,

    /// Per-property layouts, in declaration order.
    properties: []const PropertyLayout,
};

/// Compiles the header's elements into `ElementLayout`s.
///
/// `allocator` is typically the header metadata arena, so the layouts share
/// the header's single cleanup path. Overflow in any width or size
/// calculation is reported as `error.NumericOverflow` — never wrapped.
pub fn compileSchema(
    allocator: std.mem.Allocator,
    header: *const Header,
) HeaderError![]ElementLayout {
    const layouts = try allocator.alloc(ElementLayout, header.elements.len);
    errdefer allocator.free(layouts);

    // Running body position, valid only while every previous element had a
    // known fixed body size.
    var body_offset: u64 = 0;
    var body_resolved = true;

    for (header.elements, 0..) |*element, i| {
        const property_layouts = try allocator.alloc(PropertyLayout, element.properties.len);
        errdefer allocator.free(property_layouts);

        // Running record offset, valid only while no list has been seen.
        var running: usize = 0;
        var resolved = true;
        var minimum: usize = 0;

        for (element.properties, 0..) |property, pi| {
            // A property's start offset is fixed exactly when all preceding
            // properties were fixed-width.
            const start: ?usize = if (resolved) running else null;

            switch (property.kind) {
                .scalar => |t| {
                    const width = t.byteWidth();
                    if (resolved) {
                        running = try addChecked(running, width);
                    }
                    minimum = try addChecked(minimum, width);
                    property_layouts[pi] = .{
                        .property_index = pi,
                        .fixed_offset = start,
                        .fixed_width = width,
                        .scalar_type = t,
                        .binary_op = .{ .scalar = .{
                            .scalar_type = t,
                            .width = width,
                        } },
                    };
                },
                .list => |list| {
                    // The count prefix's *start* may be fixed, but the
                    // property is variable-width overall, and every later
                    // offset becomes unresolved.
                    resolved = false;
                    minimum = try addChecked(minimum, list.count_type.byteWidth());
                    property_layouts[pi] = .{
                        .property_index = pi,
                        .fixed_offset = start,
                        .fixed_width = null,
                        .scalar_type = null,
                        .binary_op = .{ .list = .{
                            .count_type = list.count_type,
                            .count_width = list.count_type.byteWidth(),
                            .item_type = list.item_type,
                            .item_width = list.item_type.byteWidth(),
                        } },
                    };
                },
            }
        }

        var fixed_record_size: ?usize = null;
        var fixed_body_size: ?u64 = null;
        if (resolved) {
            fixed_record_size = running;
            fixed_body_size = std.math.mul(u64, element.count, @as(u64, running)) catch
                return error.NumericOverflow;
        }

        const start_offset: ?u64 = if (body_resolved) body_offset else null;

        layouts[i] = .{
            .element_index = i,
            .fixed_record_size = fixed_record_size,
            .minimum_record_size = minimum,
            .body_start_offset = start_offset,
            .fixed_body_size = fixed_body_size,
            .properties = property_layouts,
        };

        if (fixed_body_size) |size| {
            body_offset = std.math.add(u64, body_offset, size) catch
                return error.NumericOverflow;
        } else {
            body_resolved = false;
        }
    }

    return layouts;
}

/// Checked `a + b` for width arithmetic.
fn addChecked(a: usize, b: usize) HeaderError!usize {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.NumericOverflow;
    return result[0];
}
