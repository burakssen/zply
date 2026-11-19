//! Fixed-width record decoding over compiled PLY layouts.
//!
//! This layer turns raw record bytes into typed values using the layouts
//! compiled in Phase 2. Its contract with its callers is deliberately
//! strict so the decoding kernels can stay simple and allocation-free:
//!
//! * **Validate once, decode many.** `FixedLayout` wraps an
//!   `ElementLayout` after checking every fixed-width invariant (all
//!   properties scalar, widths matching their declared types, non-
//!   overlapping ranges exactly covering the record). All decoding
//!   functions take a `FixedLayout`, never a raw layout, so malformed
//!   layouts cannot reach the kernels.
//! * **Checked dimensions, controlled errors.** Every length, offset,
//!   and index entering a decode operation is validated against the
//!   actual slice lengths; no arithmetic wraps, nothing panics on
//!   caller-supplied data.
//! * **No allocation, no I/O, no state.** The decoder is pure: it never
//!   allocates, never reads a stream, and holds no shared mutable state,
//!   so two tasks decoding disjoint slices never synchronize.
//!
//! Variable-length (list-containing) elements are explicitly out of
//! scope here: the fixed-width APIs reject them with
//! `VariableLengthElement` rather than guessing at runtime lengths.

const std = @import("std");
const types = @import("../format/types.zig");
const layout_mod = @import("../format/layout.zig");
const binary = @import("binary.zig");
const value_mod = @import("value.zig");

const ScalarType = types.ScalarType;
const ElementLayout = layout_mod.ElementLayout;
const PropertyLayout = layout_mod.PropertyLayout;
const ScalarValue = value_mod.ScalarValue;

pub const DecodeError = binary.DecodeError;

/// A compiled element layout that has been validated for fixed-width
/// decoding, paired with the byte order it must be decoded in.
///
/// Construct through `init` (explicit byte order) or `initForEncoding`
/// (maps a PLY encoding and rejects `ascii`). The referenced
/// `ElementLayout` must outlive every decode operation using it; the
/// wrapper holds no data of its own beyond a pointer, a size, and the
/// byte order.
pub const FixedLayout = struct {
    /// The validated compiled layout. Borrowed.
    element: *const ElementLayout,

    /// The element's fixed per-record byte size (equal to
    /// `element.fixed_record_size.?` after validation).
    record_size: usize,

    /// Byte order of the bytes being decoded.
    endian: std.builtin.Endian,

    /// Number of properties in the element (convenience, exact).
    pub fn propertyCount(fixed: FixedLayout) usize {
        return fixed.element.properties.len;
    }

    /// Validates `element` for fixed-width decoding and wraps it.
    ///
    /// Invariants enforced (see Task 3.10):
    ///
    /// 1. `fixed_record_size` is present (the element is fixed-width).
    /// 2. Every property is scalar (`fixed_width` and `fixed_offset`
    ///    present, `scalar_type` declared).
    /// 3. Every property width equals its declared scalar type's width.
    /// 4. Property ranges do not overlap, are in declaration order, and
    ///    exactly cover the record: the first range starts at 0 and each
    ///    subsequent range starts where the previous one ends.
    /// 5. The final range ends exactly at `fixed_record_size` (no
    ///    unserialized gaps).
    ///
    /// An empty element (zero properties) is valid with `record_size 0`.
    pub fn init(
        element: *const ElementLayout,
        endian: std.builtin.Endian,
    ) error{ InvalidLayout, VariableLengthElement }!FixedLayout {
        const record_size = element.fixed_record_size orelse
            return error.VariableLengthElement;

        var running: usize = 0;
        for (element.properties) |property| {
            const offset = property.fixed_offset orelse return error.InvalidLayout;
            const width = property.fixed_width orelse return error.VariableLengthElement;
            const scalar_type = property.scalar_type orelse return error.InvalidLayout;

            if (width != scalar_type.byteWidth()) return error.InvalidLayout;
            if (offset != running) return error.InvalidLayout;
            running = std.math.add(usize, offset, width) catch return error.InvalidLayout;
            if (running > record_size) return error.InvalidLayout;
        }
        if (running != record_size) return error.InvalidLayout;

        return .{ .element = element, .record_size = record_size, .endian = endian };
    }

    /// `init` plus the PLY encoding → byte order mapping: `ascii` (or any
    /// future non-binary encoding) is rejected before any decoding.
    pub fn initForEncoding(
        element: *const ElementLayout,
        encoding: types.Encoding,
    ) (DecodeError || error{ InvalidLayout, VariableLengthElement })!FixedLayout {
        return init(element, try binary.endianFor(encoding));
    }
};

/// Decodes one scalar property from a record by its compiled property
/// index — no name lookup, no schema re-interpretation.
///
/// The record slice does not need to be exactly one record long: only
/// the property's byte range is required to be present (`offset + width
/// ≤ record.len`), so single-property access works on prefixes and on
/// buffers holding several records. The property must be scalar; list
/// properties have no fixed-width scalar value and are rejected.
pub fn decodeProperty(
    fixed: FixedLayout,
    property_index: usize,
    record: []const u8,
) error{ InvalidPropertyIndex, VariableLengthElement, InsufficientBytes }!ScalarValue {
    if (property_index >= fixed.propertyCount()) return error.InvalidPropertyIndex;
    const property = fixed.element.properties[property_index];

    const offset = property.fixed_offset orelse return error.VariableLengthElement;
    const width = property.fixed_width orelse return error.VariableLengthElement;
    const scalar_type = property.scalar_type orelse return error.VariableLengthElement;

    const end = std.math.add(usize, offset, width) catch return error.InsufficientBytes;
    if (end > record.len) return error.InsufficientBytes;

    return binary.decodeScalar(scalar_type, fixed.endian, record[offset..]);
}

/// Decodes one complete fixed-width record into caller-provided storage.
///
/// Contract:
///
/// * `record.len` must equal the compiled `record_size` exactly —
///   accidental partial or overlong records are detectable errors.
/// * `values.len` must equal the property count. Nothing is written and
///   no input is interpreted when either dimension is wrong.
/// * An element containing a list property is rejected
///   (`VariableLengthElement` via the `FixedLayout` construction
///   requirement, re-checked here defensively).
/// * A zero-property record (`record_size 0`) is a valid no-op.
///
/// After the preflight above, decoding cannot fail: the layout's ranges
/// exactly cover `record_size`, every byte of a structurally valid
/// binary record is a valid scalar bit pattern, and no allocation or
/// I/O occurs. (`InsufficientBytes` remains in the error set only as a
/// defensive totality measure for the shared decode primitive.)
pub fn decodeRecord(
    fixed: FixedLayout,
    record: []const u8,
    values: []ScalarValue,
) error{
    VariableLengthElement,
    InvalidRecordLength,
    InvalidOutputLength,
    InsufficientBytes,
}!void {
    if (fixed.record_size == 0 and fixed.propertyCount() == 0) {
        // Zero-property element: values.len must still be exact, but the
        // record itself occupies no bytes.
        if (values.len != 0) return error.InvalidOutputLength;
        return;
    }
    if (record.len != fixed.record_size) return error.InvalidRecordLength;
    if (values.len != fixed.propertyCount()) return error.InvalidOutputLength;

    for (fixed.element.properties, 0..) |property, i| {
        const offset = property.fixed_offset orelse return error.VariableLengthElement;
        const scalar_type = property.scalar_type orelse return error.VariableLengthElement;

        // The validated layout guarantees offset + width == record_size
        // bounds; the decode error is structurally unreachable.
        values[i] = binary.decodeScalar(
            scalar_type,
            fixed.endian,
            record[offset..],
        ) catch |err| switch (err) {
            error.InsufficientBytes => return error.InsufficientBytes,
        };
    }
}

/// Read-only, non-owning view of one raw fixed-width record.
///
/// A view decodes individual properties on demand, so a consumer
/// interested in three of twenty-five properties never materializes the
/// other twenty-two. The view is a small value type: no heap, no
/// virtual dispatch, no reflection. Its validity is tied to the
/// lifetimes of the compiled layout and the underlying bytes; it holds
/// no copies and never mutates the record.
///
/// Layout invariants (fixed-width structure, record length) are
/// validated once at construction; property access then only bounds-
/// checks the index it was given.
pub const RecordView = struct {
    fixed: FixedLayout,
    bytes: []const u8,

    /// Constructs a view over one exact-size record.
    pub fn init(
        fixed: FixedLayout,
        bytes: []const u8,
    ) error{InvalidRecordLength}!RecordView {
        if (bytes.len != fixed.record_size) return error.InvalidRecordLength;
        return .{ .fixed = fixed, .bytes = bytes };
    }

    pub fn propertyCount(view: RecordView) usize {
        return view.fixed.propertyCount();
    }

    /// Decodes the scalar property at `property_index` on demand.
    pub fn get(
        view: RecordView,
        property_index: usize,
    ) error{ InvalidPropertyIndex, VariableLengthElement, InsufficientBytes }!ScalarValue {
        return decodeProperty(view.fixed, property_index, view.bytes);
    }

    /// Decodes every property into `values` (`values.len` must equal
    /// the property count). The record length is already validated by
    /// construction, so this cannot fail for a structurally valid view.
    pub fn decodeAll(
        view: RecordView,
        values: []ScalarValue,
    ) error{ InvalidOutputLength, InsufficientBytes, VariableLengthElement }!void {
        if (values.len != view.propertyCount()) return error.InvalidOutputLength;
        for (view.fixed.element.properties, 0..) |property, i| {
            const offset = property.fixed_offset orelse return error.VariableLengthElement;
            const scalar_type = property.scalar_type orelse return error.VariableLengthElement;
            values[i] = binary.decodeScalar(
                scalar_type,
                view.fixed.endian,
                view.bytes[offset..],
            ) catch |err| switch (err) {
                error.InsufficientBytes => return error.InsufficientBytes,
            };
        }
    }
};

/// Derives the number of records in a byte range of exact size — the
/// convenience counterpart to the explicit `record_count` parameter of
/// `decodeRange`. Requires a nonzero record size and an exact
/// divisibility (trailing bytes are an error, never silently ignored).
pub fn recordCountForRange(
    bytes_len: usize,
    record_size: usize,
) error{ InvalidRecordLength, SizeOverflow }!u64 {
    if (record_size == 0) return error.InvalidRecordLength;
    if (bytes_len % record_size != 0) return error.InvalidRecordLength;
    return std.math.divExact(u64, bytes_len, record_size) catch error.SizeOverflow;
}

/// Traverses `record_count` consecutive fixed-width records from a
/// contiguous byte slice, calling `consumer` once per record with a
/// validated, exact-size `RecordView`.
///
/// The traversal is the operation the streaming producer (Phase 4) will
/// reuse on input chunks. Design notes:
///
/// * **Explicit record count.** The count is never derived from
///   `bytes.len / record_size`: that is undefined for zero-width
///   records and silently ignores trailing bytes. A convenience for
///   deriving it from an exact range exists (`recordCountForRange`).
/// * **Checked range arithmetic.** `record_count × record_size` is
///   computed with checked multiplication; an impossible range is
///   `SizeOverflow`, a short input is `InsufficientBytes`. Trailing
///   bytes beyond the declared range are left untouched — combining
///   this function with `recordCountForRange` enforces an exact range.
/// * **No shared mutable state.** Records are decoded strictly from
///   their own slices; two tasks given disjoint input slices and
///   disjoint output storage can run concurrently without
///   synchronization.
/// * **Zero-width records.** An element with no properties occupies no
///   bytes but still owns logical records: all `record_count` of them
///   are visited with empty record bytes, and no division by zero
///   occurs.
///
/// The consumer may abort traversal by returning any error, which is
/// propagated to the caller untouched.
pub fn decodeRange(
    fixed: FixedLayout,
    bytes: []const u8,
    record_count: u64,
    context: anytype,
    comptime consumer: fn (@TypeOf(context), record_index: u64, view: RecordView) anyerror!void,
) anyerror!void {
    const total = std.math.mul(u64, record_count, @as(u64, fixed.record_size)) catch
        return error.SizeOverflow;
    if (total > bytes.len) return error.InsufficientBytes;

    var index: u64 = 0;
    while (index < record_count) : (index += 1) {
        const start = index * fixed.record_size;
        const record = bytes[start..][0..fixed.record_size];
        const view = try RecordView.init(fixed, record);
        try consumer(context, index, view);
    }
}
