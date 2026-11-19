//! Directive recognition, header grammar, and header ownership.
//!
//! The parser drives the bounded line reader and enforces the PLY header
//! grammar with a small state machine:
//!
//!     expect_magic -> expect_format -> declarations -> completed
//!
//! Rules (all keywords case-sensitive; blank lines are skipped):
//!
//! * The first directive must be exactly `ply` (one token).
//! * The next directive must be `format encoding version`; a second
//!   `format` is a duplicate. Any other directive before `format` —
//!   including comments — is a missing-format error.
//! * `element` requires exactly a name and a decimal `u64` record count
//!   (never parsed as float; no record storage is allocated from it).
//! * `property` requires an active element, and is either
//!   `property type name` or `property list count_type item_type name`.
//!   A list count type must be an integer.
//! * `comment`/`obj_info` payloads are free text: one separator after the
//!   keyword is excluded, interior spacing is preserved, and the active
//!   element is *not* reset.
//! * `end_header` terminates the header; parsing stops there and every
//!   following byte belongs to the body.
//!
//! Ownership: all metadata is allocated from one arena (see
//! `HeaderStorage`). Nothing returned by the line reader is stored without
//! being duplicated. Any failure destroys the arena before the error
//! escapes, so a failed `parseHeader` leaves nothing to clean up.
//!
//! Reader contract: the parser advances the caller's reader from its
//! current logical position through the `end_header` newline and stops —
//! it never reads a logical body byte (the reader may have prefetched into
//! its buffer; that concerns the reader's buffer, not the logical
//! position). Initialization is *not* transactional with respect to the
//! reader: on failure the reader stays wherever parsing stopped; the
//! parser frees its allocations but never rewinds the caller's reader.

const std = @import("std");
const errors = @import("../errors.zig");
const options_mod = @import("../options.zig");
const types = @import("types.zig");
const header_reader = @import("header_reader.zig");
const header_builder = @import("header_builder.zig");
const header_mod = @import("header.zig");
const layout_mod = @import("layout.zig");

const Options = options_mod.Options;
const HeaderError = errors.HeaderError;
const Header = header_mod.Header;
const Version = types.Version;
const HeaderBuilder = header_builder.HeaderBuilder;

/// The result of a successful `parseHeader`: the public header plus the
/// arena that owns it and the compiled element layouts.
///
/// Returned by value; the arena's heap allocations are unaffected by the
/// move. `deinit` releases everything (header, layouts, names, payloads).
pub const HeaderStorage = struct {
    header: Header,

    /// Owns `header` (all names and slices) and `layouts`.
    arena_state: std.heap.ArenaAllocator,

    /// Compiled layouts, one per element in header order. Allocated from
    /// `arena_state`.
    layouts: []const layout_mod.ElementLayout,

    /// Releases all header metadata and compiled layouts. The caller's
    /// reader and allocator are untouched.
    pub fn deinit(storage: *HeaderStorage) void {
        storage.arena_state.deinit();
    }
};

/// Grammar states.
const State = enum {
    /// Waiting for the `ply` signature.
    expect_magic,
    /// Waiting for the `format` declaration.
    expect_format,
    /// Elements, properties, comments, and object info.
    declarations,
    /// `end_header` seen; parsing has stopped.
    completed,
};

/// Snapshot of parsing progress to report a failure after the header parser
/// has released its arena. No values here point into arena-owned memory.
const HeaderProgress = struct {
    state: State = .expect_magic,
    line_number: u64 = 1,
    byte_offset: u64 = 0,
    failure_byte_offset: u64 = 0,
    directive: ?errors.Diagnostic.Directive = null,
    element_index: ?u64 = null,
    property_index: ?u64 = null,
};

/// Parses the header from the reader's current position.
///
/// `gpa` backs the arena and the (bounded) line scratch buffer. On success
/// the reader is logically positioned at the first body byte. On failure
/// all parser-owned allocations are released and the error is one of
/// `HeaderError`; the reader is left wherever parsing stopped.
pub fn parseHeader(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
) HeaderError!HeaderStorage {
    return parseHeaderDetailed(gpa, reader, options, null);
}

/// Optional allocation-free diagnostics for failures before Parser exists.
/// The output pointer is borrowed for this call only. On success its `code`
/// remains null; on failure it records the exact HeaderError and progress.
pub fn parseHeaderDetailed(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
    diagnostic: ?*errors.Diagnostic,
) HeaderError!HeaderStorage {
    var progress: HeaderProgress = .{};
    if (diagnostic) |out| out.* = .{ .category = .header, .stage = .header };

    // Zig 0.17 removed error capture from errdefer. Capture the error
    // at the function boundary, after the inner parser records its location
    // in stable stack-owned storage and releases its allocations.
    return parseHeaderImpl(gpa, reader, options, &progress) catch |err| {
        if (diagnostic) |out| {
            out.* = errors.Diagnostic.fromError(err, if (progress.state == .completed) .schema else .header);
            out.line_number = progress.line_number;
            out.byte_offset = progress.byte_offset;
            out.failure_byte_offset = progress.failure_byte_offset;
            out.directive = progress.directive;
            out.element_index = progress.element_index;
            out.property_index = progress.property_index;
        }
        return err;
    };
}

fn parseHeaderImpl(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: Options,
    progress: *HeaderProgress,
) HeaderError!HeaderStorage {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var line_reader = header_reader.HeaderLineReader.init(reader, gpa, options);
    defer line_reader.deinit();

    var builder = HeaderBuilder.init(arena, options);
    var state: State = .expect_magic;
    var current_line_start: u64 = 0;
    var current_line_number: u64 = 1;
    var current_directive: ?errors.Diagnostic.Directive = null;
    var reading_line = false;

    // Defers run in reverse order: capture builder context before the arena
    // is destroyed, so the outer catch handler never touches freed storage.
    defer {
        progress.state = state;
        progress.line_number = if (reading_line) line_reader.line_number + 1 else current_line_number;
        progress.byte_offset = current_line_start;
        progress.failure_byte_offset = line_reader.bytes_consumed;
        progress.directive = current_directive;
        if (current_directive == .property or state == .completed) {
            if (builder.active_element) |element_index| {
                progress.element_index = @intCast(element_index);
                if (current_directive == .property)
                    progress.property_index = @intCast(builder.elements.items[element_index].properties.items.len);
            }
        }
    }

    while (true) {
        current_line_start = line_reader.bytes_consumed;
        current_line_number = line_reader.line_number + 1;
        current_directive = null;
        reading_line = true;
        const maybe_line = try line_reader.nextLine();
        reading_line = false;
        const line = maybe_line orelse break;
        try validateLineBytes(line, options.strict);

        var tokens = Tokens{ .line = line };
        const keyword = tokens.next() orelse continue; // blank line: skip
        current_directive = if (std.mem.eql(u8, keyword, "ply")) .magic else if (std.mem.eql(u8, keyword, "format")) .format else if (std.mem.eql(u8, keyword, "element")) .element else if (std.mem.eql(u8, keyword, "property")) .property else if (std.mem.eql(u8, keyword, "comment")) .comment else if (std.mem.eql(u8, keyword, "obj_info")) .obj_info else if (std.mem.eql(u8, keyword, "end_header")) .end_header else null;

        switch (state) {
            .expect_magic => if (!std.mem.eql(u8, keyword, "ply")) return error.InvalidMagic,
            .expect_format => if (!std.mem.eql(u8, keyword, "format")) return error.MissingFormat,
            .declarations => {},
            .completed => unreachable, // the loop breaks immediately on completion
        }

        if (std.mem.eql(u8, keyword, "ply")) {
            // The signature must be a single token, and only the first
            // directive line may carry it (a second `ply` inside the header
            // is rejected).
            if (state != .expect_magic) return error.InvalidMagic;
            if (tokens.next() != null) return error.InvalidMagic;
            state = .expect_format;
        } else if (std.mem.eql(u8, keyword, "format")) {
            switch (state) {
                .expect_format => {},
                .declarations => return error.DuplicateFormat,
                else => return error.InvalidDirective,
            }
            const encoding_token = tokens.next() orelse return error.UnsupportedEncoding;
            const encoding = types.Encoding.fromFormatName(encoding_token) catch
                return error.UnsupportedEncoding;
            const version_token = tokens.next() orelse return error.InvalidVersion;
            if (tokens.next() != null) return error.InvalidDirective;

            const version = try parseVersionToken(version_token);
            if (!Header.isSupportedVersion(version)) return error.UnsupportedVersion;

            builder.setFormat(encoding, version);
            state = .declarations;
        } else if (std.mem.eql(u8, keyword, "element")) {
            const name_token = tokens.next() orelse return error.InvalidElement;
            const count_token = tokens.next() orelse return error.InvalidElement;
            if (tokens.next() != null) return error.InvalidElement;
            const count = try parseRecordCount(count_token);
            try builder.addElement(name_token, count);
        } else if (std.mem.eql(u8, keyword, "property")) {
            try parsePropertyLine(&builder, &tokens);
        } else if (std.mem.eql(u8, keyword, "comment")) {
            try builder.addComment(freeTextPayload(line, tokens.pos));
        } else if (std.mem.eql(u8, keyword, "obj_info")) {
            try builder.addObjInfo(freeTextPayload(line, tokens.pos));
        } else if (std.mem.eql(u8, keyword, "end_header")) {
            if (tokens.next() != null) return error.InvalidDirective;
            state = .completed;
            break; // Every following byte belongs to the body.
        } else {
            return error.InvalidDirective;
        }
    }

    // Clean EOF is only acceptable at a line boundary after `end_header`;
    // the line reader turns EOF inside a line into its own error.
    if (state != .completed) return error.UnexpectedEndOfHeader;

    const header = try builder.finalize(line_reader.bytes_consumed);
    const layouts = try layout_mod.compileSchema(arena, &header);

    return .{
        .header = header,
        .arena_state = arena_state,
        .layouts = layouts,
    };
}

/// Rejects NUL bytes everywhere, and (strict mode only) control bytes other
/// than horizontal tab. Line terminators never appear here: the line reader
/// strips `\n`, strips the `\r` of a CRLF, and rejects a bare `\r` itself.
fn validateLineBytes(line: []const u8, strict: bool) HeaderError!void {
    for (line) |byte| {
        if (byte == 0) return error.InvalidDirective;
        if (strict and byte < 0x20 and byte != '\t') return error.InvalidDirective;
    }
}

/// Non-owning token iterator over one line. Tokens are separated by spaces
/// and/or tabs and point into the line scratch buffer; anything that must
/// survive the line is duplicated by the builder.
const Tokens = struct {
    line: []const u8,
    pos: usize = 0,

    fn next(self: *Tokens) ?[]const u8 {
        while (self.pos < self.line.len and
            (self.line[self.pos] == ' ' or self.line[self.pos] == '\t')) : (self.pos += 1)
        {}
        if (self.pos == self.line.len) return null;
        const start = self.pos;
        while (self.pos < self.line.len and
            self.line[self.pos] != ' ' and self.line[self.pos] != '\t') : (self.pos += 1)
        {}
        return self.line[start..self.pos];
    }
};

/// Extracts the free-text payload of a `comment`/`obj_info` line.
///
/// `keyword_end` is the tokenizer cursor after the keyword, not the keyword
/// length: directives may be indented, and `line[keyword.len..]` would then
/// truncate the metadata. Exactly one separator (space or tab) immediately
/// after the keyword is excluded; all further spacing is preserved.
fn freeTextPayload(line: []const u8, keyword_end: usize) []const u8 {
    var rest = line[keyword_end..];
    if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    return rest;
}

/// Parses a `property` line (scalar or list form).
fn parsePropertyLine(builder: *HeaderBuilder, tokens: *Tokens) HeaderError!void {
    const second = tokens.next() orelse return error.InvalidProperty;

    if (std.mem.eql(u8, second, "list")) {
        // property list count_type item_type name
        const count_token = tokens.next() orelse return error.InvalidProperty;
        const item_token = tokens.next() orelse return error.InvalidProperty;
        const name_token = tokens.next() orelse return error.InvalidProperty;
        if (tokens.next() != null) return error.InvalidProperty;

        const count_scalar = resolveScalarType(count_token, builder.strict) catch
            return error.InvalidScalarType;
        const count_type = types.IntegerType.fromScalar(count_scalar) catch
            return error.InvalidListCountType;
        const item_type = resolveScalarType(item_token, builder.strict) catch
            return error.InvalidScalarType;
        try builder.addListProperty(name_token, count_type, item_type);
    } else {
        // property type name
        const name_token = tokens.next() orelse return error.InvalidProperty;
        if (tokens.next() != null) return error.InvalidProperty;

        const scalar_type = resolveScalarType(second, builder.strict) catch
            return error.InvalidScalarType;
        try builder.addScalarProperty(name_token, scalar_type);
    }
}

/// Resolves a scalar type name.
///
/// Strict mode: canonical names plus the standard integer aliases
/// (`int8`..`uint32`), case-sensitive. Compatibility mode additionally
/// accepts case-insensitive spellings and the `float32`/`float64` aliases.
/// Unsupported 64-bit integer names are not enabled by either mode.
fn resolveScalarType(
    token: []const u8,
    strict: bool,
) error{InvalidScalarType}!types.ScalarType {
    if (strict) {
        return types.ScalarType.fromName(token) catch error.InvalidScalarType;
    }
    if (types.ScalarType.fromNameCompatible(token)) |scalar_type| {
        return scalar_type;
    } else |_| {}
    if (std.ascii.eqlIgnoreCase(token, "float32")) return .f32;
    if (std.ascii.eqlIgnoreCase(token, "float64")) return .f64;
    return error.InvalidScalarType;
}

/// Parses the `format` version token as an exact `major.minor` pair of
/// decimal integers — never as a floating-point number. Supported-version
/// policy (PLY 1.0) is applied by the caller.
fn parseVersionToken(token: []const u8) HeaderError!Version {
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return error.InvalidVersion;
    const major = parseVersionComponent(token[0..dot]) catch return error.InvalidVersion;
    const minor = parseVersionComponent(token[dot + 1 ..]) catch return error.InvalidVersion;
    return .{ .major = major, .minor = minor };
}

fn parseVersionComponent(component: []const u8) error{Invalid}!u16 {
    if (component.len == 0 or component.len > 5) return error.Invalid;
    for (component) |byte| {
        if (byte < '0' or byte > '9') return error.Invalid;
    }
    return std.fmt.parseInt(u16, component, 10) catch error.Invalid;
}

/// Parses an element record count: decimal digits only, checked against
/// `u64`. The count is stored as `u64` (not `usize`) so declarations larger
/// than the addressable record count of a single allocation remain
/// representable — and no record storage is ever allocated from it.
fn parseRecordCount(token: []const u8) HeaderError!u64 {
    for (token) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidElement;
    }
    return std.fmt.parseInt(u64, token, 10) catch |err| switch (err) {
        error.Overflow => error.NumericOverflow,
        // Unreachable after the digit check; kept total anyway.
        error.InvalidCharacter => error.InvalidElement,
    };
}
