//! Parser configuration: resource options and defensive limits.
//!
//! Configuration is focused on parsing behavior and resource management. It
//! deliberately contains no `workers`, `threads`, or `max_parallel_tasks`
//! fields: the parser later derives the amount of outstanding work from
//! memory availability and task costs, and the supplied `std.Io`
//! implementation handles execution. Adding concurrency knobs here would
//! couple the public API to a particular execution strategy.
//!
//! `chunk_size <= memory_budget` is necessary but not sufficient to
//! guarantee a chunk fits the budget: decoded output and scratch storage
//! also consume memory. The streaming admission controller verifies this
//! at runtime without consuming input when no batch can be admitted.

const std = @import("std");
const types = @import("format/types.zig");

/// Defensive caps protecting the parser from unreasonable input
/// declarations. Every value is configurable so legitimate files with
/// unusual schemas are not rejected; the defaults are proposals, not
/// guarantees.
pub const Limits = struct {
    /// Maximum total bytes the header may occupy, including `end_header`.
    /// Headers larger than this are rejected before they can force
    /// unbounded buffering.
    max_header_bytes: usize = 1024 * 1024,

    /// Maximum bytes of a single header line. Protects the line scanner
    /// from a hostile unterminated "line" that would otherwise grow without
    /// bound.
    max_header_line_bytes: usize = 64 * 1024,

    /// Maximum number of `element` declarations.
    max_elements: usize = 1024,

    /// Maximum `property` declarations within one element.
    max_properties_per_element: usize = 4096,

    /// Maximum `property` declarations across the whole header. Must be at
    /// least `max_properties_per_element` (checked in `Options.validate`).
    max_total_properties: usize = 16384,

    /// Maximum byte width of one fixed-width record. Rejects absurd schemas
    /// like a million `double` properties long before a record is decoded;
    /// the value must at least hold the widest scalar (8 bytes).
    max_record_bytes: usize = 64 * 1024 * 1024,

    /// Maximum ASCII body line, excluding LF/CRLF.
    max_ascii_record_bytes: usize = 8 * 1024 * 1024,
    /// Maximum one numeric token in an ASCII body record.
    max_ascii_token_bytes: usize = 4 * 1024,
    /// Maximum number of list items in one ASCII list property.
    max_list_items_per_record: usize = 1_000_000,
};

/// Parser options.
pub const Options = struct {
    /// Maximum accounted allocator-requested capacity, including metadata,
    /// raw input, pool storage and pending allocation reservations. Excludes
    /// caller-owned memory and allocator-internal overhead. Admission,
    /// adaptive batch sizing, and reclamation enforce this at runtime.
    memory_budget: usize = 256 * 1024 * 1024,

    /// Preferred raw input chunk size: how many bytes the parser asks the
    /// reader for per batch of undecoded input. A hint, not a guarantee:
    /// readers may deliver short reads, and `chunk_size` need not divide
    /// `memory_budget` evenly.
    chunk_size: usize = 4 * 1024 * 1024,

    /// Preserve element/record order. When false, completed decode batches
    /// may arrive out of sequence; batch metadata retains original offsets.
    preserve_order: bool = true,

    /// Apply strict PLY validation. When `true`, only canonical spellings
    /// and standard-conforming declarations are accepted (for example,
    /// scalar type-name lookup is case-sensitive via
    /// `ScalarType.fromName`). When `false`, a documented compatibility
    /// policy applies (e.g. `ScalarType.fromNameCompatible`).
    strict: bool = true,

    /// Resource limits.
    limits: Limits = .{},

    /// A pure validation function: reports whether this configuration is
    /// internally consistent. Performs no I/O and allocates nothing, so it
    /// is also callable before a parser exists.
    ///
    /// Rules:
    ///
    /// * `memory_budget` must be nonzero.
    /// * `chunk_size` must be nonzero and no larger than `memory_budget`
    ///   (a chunk is parser-owned memory; a chunk that cannot fit the
    ///   budget would violate the budget immediately). `chunk_size` is *not*
    ///   required to divide the budget evenly.
    /// * All limit values must be nonzero.
    /// * `max_header_line_bytes` must not exceed `max_header_bytes`.
    /// * `max_properties_per_element` must not exceed
    ///   `max_total_properties`.
    /// * `max_record_bytes` must be at least `ScalarType.max_width`.
    ///
    /// Everything else — including whether a chunk of this size actually
    /// leaves room for decoded output and scratch storage — is validated by
    /// the streaming admission controller, not here.
    pub fn validate(options: Options) ValidationError!void {
        const l = options.limits;

        if (options.memory_budget == 0) return error.InvalidConfiguration;
        if (options.chunk_size == 0) return error.InvalidConfiguration;
        if (options.chunk_size > options.memory_budget) return error.InvalidConfiguration;

        if (l.max_header_bytes == 0) return error.InvalidConfiguration;
        if (l.max_header_line_bytes == 0) return error.InvalidConfiguration;
        if (l.max_header_line_bytes > l.max_header_bytes) return error.InvalidConfiguration;

        if (l.max_elements == 0) return error.InvalidConfiguration;
        if (l.max_properties_per_element == 0) return error.InvalidConfiguration;
        if (l.max_total_properties == 0) return error.InvalidConfiguration;
        if (l.max_properties_per_element > l.max_total_properties) return error.InvalidConfiguration;

        if (l.max_ascii_record_bytes == 0 or l.max_ascii_token_bytes == 0 or l.max_list_items_per_record == 0) return error.InvalidConfiguration;
        if (l.max_ascii_token_bytes > l.max_ascii_record_bytes) return error.InvalidConfiguration;
        if (l.max_record_bytes == 0) return error.InvalidConfiguration;
        if (l.max_record_bytes < types.ScalarType.max_width) return error.InvalidConfiguration;
    }

    pub const ValidationError = error{InvalidConfiguration};
};
