//! zply — a high-performance streaming parser for the PLY (Polygon File
//! Format), built for Zig 0.17's native `std.Io`.
//!
//! Reader-first: the parser borrows any `std.Io.Reader` (a fixed memory
//! buffer, a file, a socket, a mid-stream slice of something larger) and
//! never owns, closes, seeks, or resets it. The caller owns the allocator,
//! the `std.Io` implementation, and the reader; the parser owns only its
//! parsed metadata and, in later phases, its buffers and task state.
//!
//! ## Intended usage (functional from Phase 2 onward)
//!
//! ```zig
//! const ply = @import("ply");
//!
//! var reader: std.Io.Reader = .fixed(ply_bytes);
//! var parser = try ply.Parser.init(allocator, io, &reader, .{});
//! defer parser.deinit();
//!
//! const header = parser.header();
//! for (header.elements) |element| { ... }
//!
//! while (try parser.next()) |batch| { ... }
//! ```
//!
//! ## Public API surface
//!
//! Parser     — borrowed Reader + Io + Allocator + Options
//! Options    — memory_budget, chunk_size, preserve_order, strict, Limits
//! Header     — encoding, version, elements, comments, obj_info, body_offset
//! Element    — name, record count, ordered properties
//! Property   — scalar value or (count_type, item_type) list
//! ScalarType — the eight canonical PLY 1.0 scalar types
//! IntegerType — integer-only subset used for list counts
//! ElementLayout — compiled per-element record layout
//! PropertyLayout — compiled per-property offsets/widths/types
//! ScalarValue — typed decoded scalar (tagged union)
//! decode      — pure binary decoding engine (values, records, ranges)
//! Batch      — record batch delivered by `next`
//!
//! The API is independent of the filesystem, of OS handles, of the
//! concurrency implementation, and of point-cloud semantics. Property names
//! like `x`, `y`, `z`, or `vertex_indices` are conventions, never hardcoded
//! assumptions.
//!
//! ## Error handling
//!
//! Every operation exposes a narrow error set; `Error` is the documented
//! union of all parser errors, and `Diagnostic` defines the (wide-typed,
//! relative-offset) diagnostic shape for later phases.

const std = @import("std");

/// Streaming PLY parser: lifecycle, ownership, and batching API.
pub const Parser = @import("parser.zig").Parser;

/// A batch of decoded records delivered by `Parser.next`.
pub const Batch = @import("parser.zig").Batch;
pub const BatchInfo = @import("batch/storage.zig").BatchInfo;
pub const Column = @import("batch/column.zig").Column;
pub const ScalarColumn = @import("batch/column.zig").ScalarColumn;
pub const ListColumn = @import("batch/column.zig").ListColumn;
pub const MemoryStats = @import("memory/budget.zig").MemoryStats;

/// Parser options (memory budget, chunking, strictness).
pub const Options = @import("options.zig").Options;

/// Defensive resource limits applied to input declarations.
pub const Limits = @import("options.zig").Limits;

/// The three standard PLY encodings.
pub const Encoding = @import("format/types.zig").Encoding;

/// PLY format version representation (PLY 1.0 is the supported policy).
pub const Version = @import("format/types.zig").Version;

/// The eight canonical PLY 1.0 scalar types.
pub const ScalarType = @import("format/types.zig").ScalarType;

/// Integer-only subset of `ScalarType` (list count types).
pub const IntegerType = @import("format/types.zig").IntegerType;

/// One property declaration: scalar or count-prefixed list.
pub const Property = @import("format/property.zig").Property;

/// One element declaration: name, record count, ordered properties.
pub const Element = @import("format/element.zig").Element;

/// A complete parsed header, owned by the parser.
pub const Header = @import("format/header.zig").Header;

/// Compiled layout of one property within its element.
pub const PropertyLayout = @import("format/layout.zig").PropertyLayout;

/// Compiled layout of one element (fixed/variable record widths, body
/// offsets).
pub const ElementLayout = @import("format/layout.zig").ElementLayout;

/// One decoded scalar value, preserving its declared numeric type.
pub const ScalarValue = @import("decode/value.zig").ScalarValue;

/// The pure binary decoding engine (endian dispatch, property/record/
/// range decoding over compiled layouts). Phase 4's streaming producer
/// feeds it bytes; it never performs I/O or allocation itself.
pub const decode = @import("decode/root.zig");

/// The union of every error the parser can report, documented per phase.
pub const Error = @import("errors.zig").Error;

/// Diagnostic shape for error locations (categories, wide indices, relative
/// byte offsets).
pub const Diagnostic = @import("errors.zig").Diagnostic;

test {
    std.testing.refAllDecls(@This());
}
