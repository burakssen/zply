//! Internal declarations re-exported for the library's own test suites.
//!
//! This module is *not* part of the public API surface and is never
//! imported by the root module. It exists so `tests/*.zig` files can reach
//! internal implementation units (the bounded line reader, the header
//! parser/builder, and the layout compiler) without exposing them through
//! `root.zig`.
//!
//! Note: declarations imported through this module belong to the internals
//! module's own compilation, so their types are distinct from the same
//! names imported via the `zply` module. Test files must not mix the two
//! universes in one expression; each test file sticks to one.
//!
//! Note: this module is not self-contained — files like
//! `format/header_parser.zig` import sibling files with relative paths, so
//! it must be imported as a package (as `build.zig` does) rather than
//! single files.

pub const errors = @import("errors.zig");
pub const options = @import("options.zig");

pub const types = @import("format/types.zig");
pub const header = @import("format/header.zig");
pub const element = @import("format/element.zig");
pub const property = @import("format/property.zig");
pub const header_reader = @import("format/header_reader.zig");
pub const header_builder = @import("format/header_builder.zig");
pub const header_parser = @import("format/header_parser.zig");
pub const layout = @import("format/layout.zig");
pub const binary_boundary = @import("input/binary_boundary.zig");
pub const binary_variable = @import("input/binary_variable.zig");
pub const binary_chunk_builder = @import("input/binary_chunk_builder.zig");
pub const binary_list_count = @import("decode/binary/list_count.zig");
pub const binary_preflight = @import("decode/binary/preflight.zig");

pub const decode = @import("decode/root.zig");
pub const input = @import("input/root.zig");
pub const ascii = @import("decode/ascii/root.zig");
pub const ascii_reader = @import("input/ascii_record_reader.zig");
pub const parser = @import("parser.zig");
pub const batch_storage = @import("batch/storage.zig");
pub const memory = @import("memory/root.zig");
pub const execution = @import("execution/root.zig");

/// Deterministic fault injection for concurrency tests; never public API.
pub const fault_injection = @import("testing/fault_injection.zig");
