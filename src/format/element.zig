//! The PLY element model: a named collection of records with an ordered list
//! of properties.
//!
//! An `element` declaration such as:
//!
//!     element vertex 1000000
//!     property double x
//!     property double y
//!     property double z
//!
//! is represented as a name, a declared record count, and the ordered
//! properties that follow it in the header. Element names are arbitrary and
//! case-sensitive; nothing here specializes to `vertex`, `face`, or any other
//! convention.
//!
//! The record width is *derived* from the properties rather than stored. A
//! derived value cannot become inconsistent with the declared properties; a
//! separate compiled-layout representation may be added in a later phase if
//! performance requires it, without changing this structural model.

const std = @import("std");
const types = @import("types.zig");
const property_mod = @import("property.zig");

const Property = property_mod.Property;

/// A single element declaration within a header.
pub const Element = struct {
    /// Element name. Arbitrary, case-sensitive, owned by the parsed header
    /// (never borrowed from the reader's buffer).
    name: []const u8,

    /// Declared number of records. `u64` so counts above 2^32 (billions of
    /// records) are representable. Batch sizes and allocations later convert
    /// to `usize` after a checked conversion.
    count: u64,

    /// Ordered property declarations, exactly as they appeared in the
    /// header. Zero properties is a valid, representable schema: such
    /// records have no payload bytes, and later streaming code must avoid
    /// zero-byte reads when advancing past them.
    properties: []const Property,

    /// Overflow while computing structural sizes.
    pub const SizeError = error{RecordSizeOverflow};

    /// Checked `a + b` for size arithmetic.
    ///
    /// Every width summation goes through this so a malformed or absurd
    /// schema can never wrap `usize` into a small, "valid-looking" record
    /// size. Exposed for testing the checked-arithmetic contract directly,
    /// since real schemas cannot construct widths that overflow.
    pub fn addSize(a: usize, b: usize) SizeError!usize {
        const result = @addWithOverflow(a, b);
        if (result[1] != 0) return error.RecordSizeOverflow;
        return result[0];
    }

    /// Whether every property is a fixed-width scalar property.
    ///
    /// An element with zero properties is fixed-width: each record carries
    /// zero payload bytes.
    pub fn isFixedWidth(element: Element) bool {
        for (element.properties) |property| {
            if (property.fixedWidth() == null) return false;
        }
        return true;
    }

    /// The per-record byte width when all properties are fixed-width
    /// scalars, or `null` when any property is a variable-length list.
    ///
    /// For:
    ///
    ///     property double x
    ///     property double y
    ///     property double z
    ///     property uchar intensity
    ///
    /// the result is `8 + 8 + 8 + 1 = 25`.
    ///
    /// Summation uses checked arithmetic (`RecordSizeOverflow` on overflow).
    /// Zero properties yields `0` — a real width, distinct from the `null`
    /// that means "unknown/variable".
    pub fn fixedRecordSize(element: Element) SizeError!?usize {
        var total: usize = 0;
        for (element.properties) |property| {
            const width = property.fixedWidth() orelse return null;
            total = try addSize(total, width);
        }
        return total;
    }

    /// Declared record count as a `usize` after checked conversion, for
    /// callers that need it as a length. Errors when the declared count does
    /// not fit `usize` (only possible on 32-bit targets for very large
    /// counts).
    pub fn countAsSize(element: Element) SizeError!usize {
        if (element.count > std.math.maxInt(usize)) return error.RecordSizeOverflow;
        return @intCast(element.count);
    }
};
