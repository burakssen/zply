//! The complete PLY header data model: the metadata representation the
//! Phase 2 header parser will populate.
//!
//! Invariants once a header is successfully parsed:
//!
//! * Encoding and version are known.
//! * Element and property declarations are immutable.
//! * All string and slice references remain valid until parser destruction.
//! * Metadata queries require no access to the reader.
//!
//! Ownership: the parser owns the element array, the property arrays, and
//! every duplicated string (element names, property names, comments,
//! `obj_info`). Nothing is borrowed from the reader's internal buffer,
//! because the reader may refill or reuse its buffer after header parsing.
//! Phase 1 represents this contract; Phase 2 implements the copying.
//!
//! Memory management is explicit: one allocator, one owner (the parser), one
//! cleanup path, so later memory-budget accounting can include schema
//! metadata without navigating an allocator hierarchy. Property names are not
//! individually interned into long-lived global storage.

const types = @import("types.zig");
const element_mod = @import("element.zig");

const Encoding = types.Encoding;
const Version = types.Version;
const Element = element_mod.Element;

/// A parsed PLY header.
pub const Header = struct {
    /// Which of the three standard encodings the file declares.
    encoding: Encoding,

    /// Declared format version, e.g. 1.0. Acceptance is a policy decision
    /// (see `isSupportedVersion`), independent of this storage.
    version: Version,

    /// Element declarations in header order, each with its ordered
    /// properties.
    elements: []const Element = &.{},

    /// Contents of `comment` lines in header order, without the keyword.
    comments: []const []const u8 = &.{},

    /// Contents of `obj_info` lines in header order, without the keyword.
    obj_info: []const []const u8 = &.{},

    /// Bytes consumed since the parser's initial logical reader position,
    /// up to (and including) the `end_header` newline.
    ///
    /// This offset is *relative* to where the parser started, not an
    /// absolute file position: the caller may hand the parser a reader that
    /// is already positioned mid-stream. The parser must never assume this
    /// is a seekable file position.
    body_offset: u64 = 0,

    /// The version this parser supports: PLY 1.0.
    ///
    /// The policy lives in header validation, not in `Version`, so future
    /// versions remain representable without changing the storage type.
    pub const supported_version: Version = .{ .major = 1, .minor = 0 };

    /// Version policy: 1.0 is supported; anything else (e.g. a hypothetical
    /// 2.0) is representable but rejected by the parser. Phase 2 enforces
    /// this when parsing the `format` line.
    pub fn isSupportedVersion(version: Version) bool {
        return version.major == supported_version.major and
            version.minor == supported_version.minor;
    }

    /// A minimal header for a given encoding, with no elements or comments.
    /// Useful for tests and for Phase 2 construction starting points; a real
    /// parsed header always overwrites `version`.
    pub fn empty(encoding: Encoding) Header {
        return .{ .encoding = encoding, .version = .{ .major = 1, .minor = 0 } };
    }

    /// Number of declared elements.
    pub fn elementCount(header: Header) usize {
        return header.elements.len;
    }

    /// Total number of declared records across all elements. Checked against
    /// `u64` overflow; datasets this large do not exist on current hardware,
    /// but the parser's contracts prefer explicit checks over silent
    /// wraparound.
    pub fn totalRecordCount(header: Header) error{NumericOverflow}!u64 {
        var total: u64 = 0;
        for (header.elements) |element| {
            total = @import("std").math.add(u64, total, element.count) catch
                return error.NumericOverflow;
        }
        return total;
    }
};
