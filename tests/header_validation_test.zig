//! Malformed-header validation tests (Task 2.13/2.14): every malformed
//! fixture is rejected through the public `Parser.init` with a precise,
//! distinguishable error, and leaks nothing.
//!
//! Uses the public `zply` module exclusively.

const std = @import("std");
const ply = @import("zply");

/// A valid header prefix used to build malformed variants.
const valid_prefix =
    "ply\n" ++
    "format ascii 1.0\n" ++
    "element vertex 3\n" ++
    "property float x\n" ++
    "end_header\n";

/// Expects `Parser.init` to fail with exactly `expected` (and, thanks to
/// the testing allocator, to leak nothing).
fn expectHeaderError(source: []const u8, expected: anyerror, options: ply.Options) !void {
    var reader: std.Io.Reader = .fixed(source);
    try std.testing.expectError(
        expected,
        ply.Parser.init(std.testing.allocator, std.testing.io, &reader, options),
    );
}

fn expectErrorDefault(source: []const u8, expected: anyerror) !void {
    try expectHeaderError(source, expected, .{});
}

// ---------------------------------------------------------------------------
// Magic
// ---------------------------------------------------------------------------

test "wrong signature is InvalidMagic" {
    try expectErrorDefault("plyx\nformat ascii 1.0\nend_header\n", error.InvalidMagic);
    try expectErrorDefault("Ply\nformat ascii 1.0\nend_header\n", error.InvalidMagic);
    try expectErrorDefault("PLY\nformat ascii 1.0\nend_header\n", error.InvalidMagic);
    try expectErrorDefault("p\nformat ascii 1.0\nend_header\n", error.InvalidMagic);
    try expectErrorDefault("element vertex 3\nformat ascii 1.0\nend_header\n", error.InvalidMagic);
}

test "signature with extra arguments is InvalidMagic" {
    try expectErrorDefault("ply extra\nformat ascii 1.0\nend_header\n", error.InvalidMagic);
}

test "second ply signature inside the header is InvalidMagic" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nply\nend_header\n",
        error.InvalidMagic,
    );
}

test "empty input is an incomplete header, not a fabricated parse" {
    try expectErrorDefault("", error.UnexpectedEndOfHeader);
}

// ---------------------------------------------------------------------------
// Format
// ---------------------------------------------------------------------------

test "missing format declaration" {
    try expectErrorDefault(
        "ply\nelement vertex 3\nproperty float x\nend_header\n",
        error.MissingFormat,
    );
    try expectErrorDefault("ply\nend_header\n", error.MissingFormat);
}

test "comment before format is rejected (declarations require format first)" {
    try expectErrorDefault(
        "ply\ncomment hello\nformat ascii 1.0\nend_header\n",
        error.MissingFormat,
    );
    try expectErrorDefault(
        "ply\nobj_info hello\nformat ascii 1.0\nend_header\n",
        error.MissingFormat,
    );
}

test "duplicate format declaration" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nformat ascii 1.0\nend_header\n",
        error.DuplicateFormat,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nformat binary_little_endian 1.0\nend_header\n",
        error.DuplicateFormat,
    );
}

test "unknown encoding is UnsupportedEncoding" {
    try expectErrorDefault("ply\nformat binary 1.0\nend_header\n", error.UnsupportedEncoding);
    try expectErrorDefault("ply\nformat ascii32 1.0\nend_header\n", error.UnsupportedEncoding);
    try expectErrorDefault("ply\nformat 1.0\nend_header\n", error.UnsupportedEncoding);
    // Case-sensitive keywords.
    try expectErrorDefault("ply\nformat ASCII 1.0\nend_header\n", error.UnsupportedEncoding);
}

test "malformed version token is InvalidVersion" {
    try expectErrorDefault("ply\nformat ascii 1\nend_header\n", error.InvalidVersion);
    try expectErrorDefault("ply\nformat ascii 1.x\nend_header\n", error.InvalidVersion);
    try expectErrorDefault("ply\nformat ascii x.y\nend_header\n", error.InvalidVersion);
    try expectErrorDefault("ply\nformat ascii 1.0.0\nend_header\n", error.InvalidVersion);
    try expectErrorDefault("ply\nformat ascii 1.0 extra\nend_header\n", error.InvalidDirective);
    try expectErrorDefault("ply\nformat ascii -1.0\nend_header\n", error.InvalidVersion);
    try expectErrorDefault("ply\nformat ascii 1.-2\nend_header\n", error.InvalidVersion);
}

test "unsupported versions are rejected as UnsupportedVersion" {
    try expectErrorDefault("ply\nformat ascii 1.1\nend_header\n", error.UnsupportedVersion);
    try expectErrorDefault("ply\nformat ascii 2.0\nend_header\n", error.UnsupportedVersion);
    try expectErrorDefault("ply\nformat ascii 0.9\nend_header\n", error.UnsupportedVersion);
    try expectErrorDefault("ply\nformat ascii 1.10\nend_header\n", error.UnsupportedVersion);
    // Component overflow is a syntactic failure, not a version policy hit.
    try expectErrorDefault("ply\nformat ascii 70000.0\nend_header\n", error.InvalidVersion);
}

test "missing version token is InvalidVersion" {
    try expectErrorDefault("ply\nformat ascii\nend_header\n", error.InvalidVersion);
}

// ---------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------

test "element with missing arguments is InvalidElement" {
    try expectErrorDefault("ply\nformat ascii 1.0\nelement\nend_header\n", error.InvalidElement);
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex\nend_header\n",
        error.InvalidElement,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement 3\nend_header\n",
        error.InvalidElement,
    );
}

test "element with extra structural arguments is InvalidElement" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 3 extra\nend_header\n",
        error.InvalidElement,
    );
}

test "negative, fractional, and overflowing element counts are rejected" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex -1\nend_header\n",
        error.InvalidElement,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1.5\nend_header\n",
        error.InvalidElement,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex +3\nend_header\n",
        error.InvalidElement,
    );
    try expectHeaderError(
        "ply\nformat ascii 1.0\nelement vertex 99999999999999999999999999\nend_header\n",
        error.NumericOverflow,
        .{},
    );
}

test "property before the first element is InvalidProperty" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nproperty float x\nend_header\n",
        error.InvalidProperty,
    );
}

test "unknown directive is InvalidDirective" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nvertex_count 3\nend_header\n",
        error.InvalidDirective,
    );
    try expectErrorDefault("ply\nformat ascii 1.0\nend_header extra\n", error.InvalidDirective);
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

test "unknown scalar type is InvalidScalarType" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float32 x\nend_header\n",
        error.InvalidScalarType,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty long x\nend_header\n",
        error.InvalidScalarType,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty FLOAT x\nend_header\n",
        error.InvalidScalarType,
    );
}

test "missing property name is InvalidProperty" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float\nend_header\n",
        error.InvalidProperty,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty list uchar int\nend_header\n",
        error.InvalidProperty,
    );
}

test "malformed property lines are InvalidProperty" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty\nend_header\n",
        error.InvalidProperty,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty list\nend_header\n",
        error.InvalidProperty,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty list uchar\nend_header\n",
        error.InvalidProperty,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x extra\nend_header\n",
        error.InvalidProperty,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty list uchar int x extra\nend_header\n",
        error.InvalidProperty,
    );
}

test "floating-point list count type is InvalidListCountType" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement face 1\nproperty list float int indices\nend_header\n",
        error.InvalidListCountType,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement face 1\nproperty list double uchar indices\nend_header\n",
        error.InvalidListCountType,
    );
}

test "unknown list count type name is InvalidScalarType" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement face 1\nproperty list flt int indices\nend_header\n",
        error.InvalidScalarType,
    );
}

test "duplicate element name under strict policy is DuplicateElement" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 3\nelement vertex 2\nend_header\n",
        error.DuplicateElement,
    );
    // Names are case-sensitive: "Vertex" is a distinct element, not a
    // duplicate of "vertex".
    var reader: std.Io.Reader = .fixed(
        "ply\nformat ascii 1.0\nelement vertex 3\nelement Vertex 2\nend_header\n",
    );
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );
    defer parser.deinit();
    try std.testing.expectEqual(@as(usize, 2), parser.header().elements.len);
}

test "duplicate property name under strict policy is DuplicateProperty" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float x\nend_header\n",
        error.DuplicateProperty,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty double x\nend_header\n",
        error.DuplicateProperty,
    );
}

test "compatibility mode accepts duplicates and non-ASCII names" {
    var options = ply.Options{};
    options.strict = false;

    // Duplicate element names are kept as separate declarations (covered in
    // the parser test suite); here we check non-ASCII property names are
    // preserved in compatibility mode.
    var reader: std.Io.Reader = .fixed(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float Übergang\nend_header\n",
    );
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        options,
    );
    defer parser.deinit();
    try std.testing.expectEqualStrings(
        "Übergang",
        parser.header().elements[0].properties[0].name,
    );
}

test "strict mode rejects non-ASCII structural names as InvalidName" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float über\nend_header\n",
        error.InvalidName,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\x01\nend_header\n",
        error.InvalidDirective, // control byte rejected at line level first
    );
}

test "NUL bytes anywhere in the header are rejected" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\x00\nend_header\n",
        error.InvalidDirective,
    );
    try expectErrorDefault(
        "ply\nformat ascii 1.0\ncomment \x00\nend_header\n",
        error.InvalidDirective,
    );
}

test "strict mode rejects control bytes other than tab" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\ncomment a\x01b\nend_header\n",
        error.InvalidDirective,
    );
}

// ---------------------------------------------------------------------------
// Termination
// ---------------------------------------------------------------------------

test "missing end_header is UnexpectedEndOfHeader" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\n",
        error.UnexpectedEndOfHeader,
    );
}

test "EOF immediately after ply is UnexpectedEndOfHeader" {
    try expectErrorDefault("ply\n", error.UnexpectedEndOfHeader);
    try expectErrorDefault("ply", error.UnexpectedEndOfHeader);
}

test "missing final newline on end_header is UnexpectedEndOfHeader" {
    try expectErrorDefault(
        "ply\nformat ascii 1.0\nend_header",
        error.UnexpectedEndOfHeader,
    );
}

test "bare CR is InvalidLineEnding" {
    try expectErrorDefault(
        "ply\rformat ascii 1.0\nend_header\n",
        error.InvalidLineEnding,
    );
}

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

test "header exceeding the total byte limit is HeaderTooLarge" {
    var options = ply.Options{};
    options.limits.max_header_bytes = 31;
    options.limits.max_header_line_bytes = 31;

    try expectHeaderError(
        valid_prefix,
        error.HeaderTooLarge,
        options,
    );
}

test "a line exceeding the line limit is HeaderLineTooLong" {
    var options = ply.Options{};
    options.limits.max_header_line_bytes = 16; // "format ascii 1.0" is 16 bytes; comment line is longer

    try expectHeaderError(
        "ply\nformat ascii 1.0\ncomment aaaaaaaaaaaaaaaaaaaaaaaa\nend_header\n",
        error.HeaderLineTooLong,
        options,
    );
}

test "element count limit is ResourceLimitExceeded" {
    var options = ply.Options{};
    options.limits.max_elements = 1;

    try expectHeaderError(
        "ply\nformat ascii 1.0\nelement a 1\nelement b 1\nend_header\n",
        error.ResourceLimitExceeded,
        options,
    );
}

test "property count limit is ResourceLimitExceeded" {
    var options = ply.Options{};
    options.limits.max_properties_per_element = 2;

    try expectHeaderError(
        "ply\nformat ascii 1.0\nelement a 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n",
        error.ResourceLimitExceeded,
        options,
    );
}

test "total property limit is ResourceLimitExceeded" {
    var options = ply.Options{};
    options.limits.max_properties_per_element = 3;
    options.limits.max_total_properties = 3;

    try expectHeaderError(
        "ply\nformat ascii 1.0\nelement a 1\nproperty float w\nproperty float x\n" ++
            "element b 1\nproperty float y\nproperty float z\nend_header\n",
        error.ResourceLimitExceeded,
        options,
    );
}

// ---------------------------------------------------------------------------
// Reader failures
// ---------------------------------------------------------------------------

const FailingReader = struct {
    interface: std.Io.Reader,

    fn init(buffer: []u8) FailingReader {
        return .{ .interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
        return error.ReadFailed;
    }

    fn readVec(_: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
        return error.ReadFailed;
    }
};

test "a reader I/O failure is ReadFailed, not a syntax error" {
    var fail_buf: [1]u8 = undefined;
    var failing: FailingReader = .init(&fail_buf);

    try std.testing.expectError(
        error.ReadFailed,
        ply.Parser.init(std.testing.allocator, std.testing.io, &failing.interface, .{}),
    );
}

// ---------------------------------------------------------------------------
// Valid control cases (making sure the rejections above are not over-broad)
// ---------------------------------------------------------------------------

test "the valid prefix still parses cleanly" {
    var reader: std.Io.Reader = .fixed(valid_prefix);
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );
    defer parser.deinit();

    const header = parser.header();
    try std.testing.expectEqual(ply.Encoding.ascii, header.encoding);
    try std.testing.expectEqual(@as(usize, 1), header.elements.len);
}

test "tab separators and blank lines are still accepted" {
    var reader: std.Io.Reader = .fixed(
        "ply\n\nformat\tascii\t1.0\n\nelement vertex 3\nproperty\tfloat x\nend_header\n",
    );
    var parser = try ply.Parser.init(
        std.testing.allocator,
        std.testing.io,
        &reader,
        .{},
    );
    defer parser.deinit();
    try std.testing.expectEqualStrings("vertex", parser.header().elements[0].name);
}
