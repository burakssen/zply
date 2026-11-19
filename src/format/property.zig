//! The PLY property model: one scalar value or one variable-length list per
//! record.
//!
//! Properties are schema-generic: nothing here specializes to vertices,
//! normals, colors, or faces. Names such as `x`, `y`, `z`, `vertex_indices`,
//! or `red` are common conventions, not restrictions; arbitrary
//! case-sensitive names are supported.
//!
//! `Property` is a pure data type — no parsing, decoding, or allocation. Name
//! strings are borrowed by this struct; ownership is defined by whoever
//! constructs the header: a parsed header must own (duplicate) its names so
//! they remain valid after the reader's buffer is refilled or reused. Phase 2
//! implements that copying; Phase 1 only fixes the contract.

const std = @import("std");
const types = @import("types.zig");

const ScalarType = types.ScalarType;
const IntegerType = types.IntegerType;

/// A single property declaration within an element.
pub const Property = struct {
    /// Property name. Case-sensitive, arbitrary content. Must be non-empty
    /// (see `validate`). The parsed header owns this memory, never the
    /// reader's buffer.
    name: []const u8,

    /// Fixed-width value or count-prefixed variable-length list. A tagged
    /// union so consumers must explicitly branch on the layout instead of
    /// inferring it from optional fields.
    kind: Kind,

    /// The two components of a list property.
    pub const List = struct {
        /// Integer type of the per-record count prefix.
        count_type: IntegerType,
        /// Scalar type of the list items that follow the count.
        item_type: ScalarType,
    };

    pub const Kind = union(enum) {
        /// One fixed-width value per record.
        scalar: ScalarType,

        /// A count of type `count_type` followed by that many `item_type`
        /// values. Record width varies per record, even for empty lists.
        list: List,
    };

    /// Validation errors for a property declaration.
    ///
    /// Phase 1 checks only name emptiness. Phase 2 enforces this while
    /// parsing the header; keeping the check here means the rule is defined
    /// once, next to the data it protects.
    pub const ValidationError = error{EmptyPropertyName};

    pub const ValidationErrorDescription = enum {
        empty_name,
    };

    /// Constructs a fixed-width scalar property, e.g. `property float x`.
    pub fn scalar(name: []const u8, t: ScalarType) Property {
        return .{ .name = name, .kind = .{ .scalar = t } };
    }

    /// Constructs a list property, e.g.
    /// `property list uchar int vertex_indices`.
    pub fn list(name: []const u8, count_type: IntegerType, item_type: ScalarType) Property {
        return .{
            .name = name,
            .kind = .{ .list = .{ .count_type = count_type, .item_type = item_type } },
        };
    }

    /// Whether this property is one fixed-width value per record.
    pub fn isScalar(property: Property) bool {
        return property.kind == .scalar;
    }

    /// Whether this property is a count-prefixed variable-length list.
    pub fn isList(property: Property) bool {
        return property.kind == .list;
    }

    /// The scalar type when this is a scalar property, otherwise `null`.
    pub fn scalarType(property: Property) ?ScalarType {
        return switch (property.kind) {
            .scalar => |t| t,
            .list => null,
        };
    }

    /// The count and item types when this is a list property, otherwise
    /// `null`.
    pub fn listInfo(property: Property) ?List {
        return switch (property.kind) {
            .scalar => null,
            .list => |l| l,
        };
    }

    /// Fixed byte width contributed per record.
    ///
    /// Scalar properties: exactly `byteWidth`.
    /// List properties: `null`, because the item count varies per record.
    ///
    /// `null` means *variable width*; it must never be encoded as `0`, since
    /// a legitimate list record (e.g. an empty face) contributes a nonzero
    /// count prefix and genuinely zero-width records are handled by the
    /// element model instead.
    pub fn fixedWidth(property: Property) ?usize {
        return switch (property.kind) {
            .scalar => |t| t.byteWidth(),
            .list => null,
        };
    }

    /// Width of the count prefix when this is a list property, otherwise
    /// `null`. Even an empty list contributes this many bytes per record.
    pub fn listCountWidth(property: Property) ?usize {
        return switch (property.kind) {
            .scalar => null,
            .list => |l| l.count_type.byteWidth(),
        };
    }

    /// Validates the property declaration.
    ///
    /// An empty name is a future validation failure: the PLY grammar always
    /// produces a token for the property name, so an empty name can only be
    /// constructed manually today. Phase 2 enforces this on every parsed
    /// `property` line.
    pub fn validate(property: Property) ValidationError!void {
        if (property.name.len == 0) return error.EmptyPropertyName;
    }
};
