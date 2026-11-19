//! Incremental construction and ownership of header metadata.
//!
//! The builder accumulates directives while the header parser validates
//! them, and finalizes an immutable `Header` once `end_header` is seen.
//!
//! Ownership model: the builder allocates exclusively from a single arena
//! (the `HeaderStorage` arena). Element and property names, comments, and
//! `obj_info` payloads are duplicated into that arena before storage, so no
//! string ever borrows the line reader's scratch buffer. The builder
//! therefore holds no resources outside the arena: on success the arena's
//! ownership transfers to `HeaderStorage`; on any failure the arena is
//! destroyed wholesale and no per-allocation bookkeeping is needed.
//!
//! The finalized header preserves declaration order exactly — element order
//! and property order are the body layout, so reordering or merging
//! declarations is never performed, not even in compatibility mode.
//! Duplicate *element* names in compatibility mode remain separate
//! declarations with distinct indices.

const std = @import("std");
const errors = @import("../errors.zig");
const options_mod = @import("../options.zig");
const types = @import("types.zig");
const property_mod = @import("property.zig");
const element_mod = @import("element.zig");
const header_mod = @import("header.zig");

const Options = options_mod.Options;
const HeaderError = errors.HeaderError;
const Property = property_mod.Property;
const Element = element_mod.Element;
const Header = header_mod.Header;

/// Incremental header builder. Create with `init` (which borrows the arena
/// allocator and the validated options), feed directives, then `finalize`.
pub const HeaderBuilder = struct {
    /// Arena allocator. Every allocation this builder makes lives in the
    /// arena; none is freed individually.
    allocator: std.mem.Allocator,

    /// Strict validation policy (from `Options.strict`).
    strict: bool,

    max_elements: usize,
    max_properties_per_element: usize,
    max_total_properties: usize,

    encoding: ?types.Encoding = null,
    version: ?types.Version = null,

    elements: std.ArrayList(ElementDraft) = .empty,
    comments: std.ArrayList([]const u8) = .empty,
    obj_info: std.ArrayList([]const u8) = .empty,

    /// Index of the element currently receiving properties, or `null`
    /// before the first `element` declaration. Comments and `obj_info`
    /// never reset this.
    active_element: ?usize = null,

    /// Number of properties appended across all elements so far.
    total_properties: usize = 0,

    /// One element under construction. `name` is arena-owned.
    pub const ElementDraft = struct {
        name: []const u8,
        count: u64,
        properties: std.ArrayList(Property) = .empty,
    };

    /// Creates a builder allocating from `allocator` (an arena allocator).
    pub fn init(allocator: std.mem.Allocator, options: Options) HeaderBuilder {
        return .{
            .allocator = allocator,
            .strict = options.strict,
            .max_elements = options.limits.max_elements,
            .max_properties_per_element = options.limits.max_properties_per_element,
            .max_total_properties = options.limits.max_total_properties,
        };
    }

    /// Records the `format` declaration. Called only after the directive
    /// parser has validated the encoding name and version.
    pub fn setFormat(self: *HeaderBuilder, encoding: types.Encoding, version: types.Version) void {
        self.encoding = encoding;
        self.version = version;
    }

    /// Adds an `element` declaration and makes it the active element.
    pub fn addElement(self: *HeaderBuilder, name: []const u8, count: u64) HeaderError!void {
        if (self.elements.items.len >= self.max_elements) return error.ResourceLimitExceeded;
        validateName(name, self.strict) catch return error.InvalidName;
        if (self.strict and self.hasElementName(name)) return error.DuplicateElement;

        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.elements.append(self.allocator, .{ .name = owned, .count = count });
        self.active_element = self.elements.items.len - 1;
    }

    /// Adds a scalar property to the active element.
    pub fn addScalarProperty(
        self: *HeaderBuilder,
        name: []const u8,
        scalar_type: types.ScalarType,
    ) HeaderError!void {
        try self.addProperty(Property.scalar(name, scalar_type), name);
    }

    /// Adds a list property to the active element. The count type has been
    /// narrowed to `IntegerType` before this call, so a floating-point
    /// count type is unrepresentable here.
    pub fn addListProperty(
        self: *HeaderBuilder,
        name: []const u8,
        count_type: types.IntegerType,
        item_type: types.ScalarType,
    ) HeaderError!void {
        try self.addProperty(Property.list(name, count_type, item_type), name);
    }

    /// Adds a `comment` payload in declaration order.
    pub fn addComment(self: *HeaderBuilder, text: []const u8) HeaderError!void {
        const owned = try self.allocator.dupe(u8, text);
        try self.comments.append(self.allocator, owned);
    }

    /// Adds an `obj_info` payload in declaration order.
    pub fn addObjInfo(self: *HeaderBuilder, text: []const u8) HeaderError!void {
        const owned = try self.allocator.dupe(u8, text);
        try self.obj_info.append(self.allocator, owned);
    }

    /// Finalizes the immutable `Header`.
    ///
    /// Element and property order is preserved exactly. All returned
    /// strings and slices live in the arena; nothing borrows the parser's
    /// line scratch buffer.
    pub fn finalize(self: *HeaderBuilder, body_offset: u64) HeaderError!Header {
        // Defensive: the directive parser enforces these earlier; a missing
        // format at this point would be an internal invariant violation.
        const encoding = self.encoding orelse return error.MissingFormat;
        const version = self.version orelse return error.MissingFormat;

        const elements = try self.allocator.alloc(Element, self.elements.items.len);
        for (self.elements.items, 0..) |*draft, i| {
            elements[i] = .{
                .name = draft.name,
                .count = draft.count,
                .properties = try draft.properties.toOwnedSlice(self.allocator),
            };
        }

        return .{
            .encoding = encoding,
            .version = version,
            .elements = elements,
            .comments = try self.comments.toOwnedSlice(self.allocator),
            .obj_info = try self.obj_info.toOwnedSlice(self.allocator),
            .body_offset = body_offset,
        };
    }

    /// Shared path for scalar and list properties.
    fn addProperty(self: *HeaderBuilder, property: Property, name: []const u8) HeaderError!void {
        const index = self.active_element orelse return error.InvalidProperty;
        const draft = &self.elements.items[index];

        if (draft.properties.items.len >= self.max_properties_per_element) {
            return error.ResourceLimitExceeded;
        }
        if (self.total_properties >= self.max_total_properties) {
            return error.ResourceLimitExceeded;
        }

        validateName(name, self.strict) catch return error.InvalidName;
        if (self.strict and elementHasProperty(draft, name)) return error.DuplicateProperty;

        const owned = try self.allocator.dupe(u8, name);
        var owned_property = property;
        owned_property.name = owned;
        try draft.properties.append(self.allocator, owned_property);
        self.total_properties += 1;
    }

    fn hasElementName(self: *HeaderBuilder, name: []const u8) bool {
        for (self.elements.items) |*draft| {
            if (std.mem.eql(u8, draft.name, name)) return true;
        }
        return false;
    }

    fn elementHasProperty(draft: *const ElementDraft, name: []const u8) bool {
        for (draft.properties.items) |property| {
            if (std.mem.eql(u8, property.name, name)) return true;
        }
        return false;
    }
};

/// Validates a structural name (element or property).
///
/// * Never empty.
/// * Never contains a NUL byte.
/// * In strict mode, only printable ASCII (`0x21`..`0x7E`): no control
///   bytes, no space (impossible for a token anyway), no non-ASCII bytes.
///   In compatibility mode, any non-NUL bytes are accepted so UTF-8 names
///   are preserved.
///
/// Names are case-sensitive and carry no special parsing semantics.
fn validateName(name: []const u8, strict: bool) error{InvalidName}!void {
    if (name.len == 0) return error.InvalidName;
    for (name) |byte| {
        if (byte == 0) return error.InvalidName;
        if (strict and (byte <= 0x20 or byte >= 0x7F)) return error.InvalidName;
    }
}
