//! Error categories and diagnostic conventions.
//!
//! The parser avoids `anyerror` wherever an explicit error set is practical:
//! each public operation exposes the narrow error set it can actually
//! produce, and `Error` below is the union of every error the parser can
//! ever report, documented by the phase that introduces it. The public
//! representation stays deliberately coarse until reading and decoding are
//! implemented; richer per-error payloads arrive with the phases that make
//! them possible.
//!
//! Failure policy:
//!
//! * Invalid configuration is never silently ignored.
//! * `unreachable` is never used for invalid user input.
//! * A failed parse is never converted into a successful EOF result.
//! * Partial initialization always cleans up before returning an error.
//! * Allocation failure is reported, never panicked on.
//!
//! Diagnostic conventions:
//!
//! * Indices and offsets use wide (`u64`) types appropriate for datasets
//!   with billions of records and multi-gigabyte streams.
//! * The byte offset in a `Diagnostic` is *relative* to the parser's initial
//!   logical reader position, matching `Header.body_offset`; it is never
//!   assumed to be a seekable file position.

/// Header parsing and validation errors. Introduced in Phase 2; produced by
/// `Parser.init` when consuming the header from the caller's reader.
pub const HeaderError = error{
    /// The first header line is not exactly `ply`.
    InvalidMagic,
    /// The header ended before a valid `format` declaration.
    MissingFormat,
    /// The encoding name is not one of the three standard encodings.
    UnsupportedEncoding,
    /// The version token is not `major.minor` decimal integers.
    InvalidVersion,
    /// The declared version is not the supported PLY 1.0.
    UnsupportedVersion,
    /// Unrecognized directive, wrong argument count, or a directive in a
    /// state where it cannot appear.
    InvalidDirective,
    /// Malformed `element` declaration.
    InvalidElement,
    /// Malformed `property` declaration.
    InvalidProperty,
    /// Unknown or nonstandard scalar type name.
    InvalidScalarType,
    /// A list property's count type is a floating-point type.
    InvalidListCountType,
    /// A duplicate `format` declaration.
    DuplicateFormat,
    /// An element name violates the duplicate policy (strict mode).
    DuplicateElement,
    /// A property name violates the duplicate policy (strict mode).
    DuplicateProperty,
    /// A structural name contains invalid characters.
    InvalidName,
    /// The header exceeded `Limits.max_header_bytes`.
    HeaderTooLarge,
    /// A single header line exceeded `Limits.max_header_line_bytes`.
    HeaderLineTooLong,
    /// The input ended before the header was complete.
    UnexpectedEndOfHeader,
    /// A carriage return appeared without a following newline inside the
    /// header line.
    InvalidLineEnding,
    /// A declared count or computed size exceeded its representable range.
    NumericOverflow,
    /// A configured resource limit (element/property counts) was exceeded.
    ResourceLimitExceeded,
    /// The underlying reader reported an I/O failure. Distinguishable from
    /// every syntax error above.
    ReadFailed,
    /// The allocator refused a parser-owned allocation.
    OutOfMemory,
};

/// Every error the parser can report, with the phase that introduces it.
pub const Error = HeaderError || @import("input/producer.zig").ProducerError ||
    error{ InvalidRecordBoundary, CountOverflow, TruncatedRecord, TruncatedListCount,
        TruncatedListPayload, InvalidReaderState, InvalidBuilderState, NegativeListCount } ||
    @import("input/ascii_record_reader.zig").RecordError ||
    @import("decode/ascii/record.zig").DecodeError || error{
    MemoryPressure,
    BatchCapacityUnavailable,
    InvalidLayout,
    InvalidColumnType,
    InvalidOutputCapacity,
    /// An `Options` value failed validation. (Phase 1)
    InvalidConfiguration,

    /// A binary record fails to decode as declared. (Phase 3 onward)
    InvalidBinaryRecord,

    /// The input ended before the declared body data did. (Phase 4 onward)
    TruncatedInput,

    /// The `std.Io` implementation reported a failure during concurrent
    /// execution. (Phase 7 onward)
    ConcurrentFailure,
};

/// Structural details attached to an error. Phase 1 defines the shape and
/// conventions only; no parsing failure exists yet to populate one.
///
/// Every field is optional because not every error has a meaningful
/// location: configuration errors carry no element/property/record context,
/// while body errors may carry all of them.
pub const Diagnostic = struct {
    /// Coarse error category retained for backwards compatibility.
    category: Category,

    /// Exact error returned by initDetailed() or next(). Static error-set
    /// value: no borrowed strings, no allocation and no lifetime coupling.
    /// Null in legacy manually constructed Diagnostic values.
    code: ?anyerror = null,

    /// Coarse recovery guidance. This is advisory: only the Parser state and
    /// its staged-input contract determine whether another next() is legal.
    /// ResourceLimitExceeded and OutOfMemory cannot be classified as
    /// universally terminal or retryable from an error value alone.
    recovery: Recovery = .terminal,

    /// Boundary where the error was discovered (not necessarily where an
    /// earlier malformed byte originated).
    stage: Stage = .input,

    /// Task sequence if a concurrent decoder reported the failure.
    chunk_sequence: ?u64 = null,

    /// Optional 1-based ASCII token column and failure-local values.
    column_number: ?usize = null,
    expected: ?u64 = null,
    actual: ?u64 = null,

    /// Failure cursor in document-relative bytes; byte_offset above remains
    /// the start of the failing line or record where known.
    failure_byte_offset: ?u64 = null,

    /// Line number within the header (1-based) where a header error
    /// occurred. Populated by header parsing failures.
    line_number: ?u64 = null,

    /// The directive being parsed when the error occurred.
    directive: ?Directive = null,

    /// Index of the element involved, in header order.
    element_index: ?u64 = null,

    /// Index of the property involved, within its element.
    property_index: ?u64 = null,

    /// Index of the record involved, within its element.
    record_index: ?u64 = null,

    /// Byte offset relative to the parser's initial logical reader
    /// position. Never assumed to be a seekable file position.
    byte_offset: ?u64 = null,

    /// Byte offset of the specific ASCII token that failed, relative to the
    /// initial parser reader position. For missing tokens, points to the
    /// record end; for errors before tokenization, remains null.
    /// `byte_offset` retains its existing record-start meaning.
    token_byte_offset: ?u64 = null,

    /// The header directive an error occurred in. Case-sensitive keywords
    /// exactly as the header parser recognizes them.
    pub const Stage = enum {
        configuration,
        header,
        schema,
        input,
        preflight,
        decode,
        scheduling,
        memory,
    };

    /// Recovery is deliberately more conservative than a `retryable: bool`:
    /// errors that have both permanent and transient call sites are marked
    /// context_dependent. Never re-enter a Parser in `.failed` state.
    pub const Recovery = enum {
        terminal,
        /// The condition may clear after a held batch is released, another
        /// task finishes, or internal storage is reclaimed. Not a promise
        /// that immediate retry succeeds.
        resource_pressure,
        /// Requires inspection of the Parser state and failure source.
        context_dependent,
    };

    pub fn recoveryFor(err: anyerror) Recovery {
        return switch (err) {
            error.MemoryPressure, error.BatchCapacityUnavailable => .resource_pressure,
            error.ResourceLimitExceeded, error.OutOfMemory => .context_dependent,
            else => .terminal,
        };
    }

    /// A complete, stable no-heap snapshot. The exact error is retained
    /// even when its category or source location is not yet known.
    pub fn fromError(err: anyerror, stage: Stage) Diagnostic {
        return .{
            .category = categoryFor(err),
            .code = err,
            .stage = stage,
            .recovery = recoveryFor(err),
        };
    }

    pub fn categoryFor(err: anyerror) Category {
        return switch (err) {
            error.InvalidConfiguration => .configuration,
            error.InvalidMagic, error.MissingFormat, error.InvalidDirective,
            error.InvalidElement, error.InvalidProperty, error.DuplicateFormat,
            error.DuplicateElement, error.DuplicateProperty, error.InvalidName,
            error.InvalidLineEnding, error.UnexpectedEndOfHeader,
            error.NumericOverflow => .header,
            error.UnsupportedEncoding => .encoding,
            error.InvalidVersion, error.UnsupportedVersion => .version,
            error.InvalidScalarType, error.InvalidListCountType => .scalar_type,
            error.TruncatedInput, error.TruncatedBody, error.TruncatedRecord,
            error.TruncatedListCount, error.TruncatedListPayload,
            error.TruncatedAsciiBody => .truncation,
            error.HeaderTooLarge, error.HeaderLineTooLong,
            error.ResourceLimitExceeded, error.RecordTooLarge, error.ListTooLarge,
            error.TokenTooLong, error.MemoryBudgetTooSmall => .resource_limit,
            error.OutOfMemory, error.MemoryPressure, error.BatchCapacityUnavailable => .memory,
            error.ReadFailed => .reader,
            error.ConcurrentFailure, error.InvalidProducerState => .execution,
            else => .record,
        };
    }

    pub fn stageFor(err: anyerror) Stage {
        return switch (err) {
            error.InvalidConfiguration => .configuration,
            error.InvalidMagic, error.MissingFormat, error.InvalidDirective,
            error.InvalidElement, error.InvalidProperty, error.DuplicateFormat,
            error.DuplicateElement, error.DuplicateProperty, error.InvalidName,
            error.InvalidLineEnding, error.UnexpectedEndOfHeader,
            error.UnsupportedEncoding, error.InvalidVersion, error.UnsupportedVersion,
            error.HeaderTooLarge, error.HeaderLineTooLong,
            error.InvalidScalarType, error.InvalidListCountType,
            error.NumericOverflow => .header,
            error.InvalidLayout => .schema,
            error.InvalidOutputCapacity, error.InvalidColumnType => .preflight,
            error.OutOfMemory, error.MemoryPressure, error.BatchCapacityUnavailable,
            error.ResourceLimitExceeded => .memory,
            error.ConcurrentFailure, error.InvalidProducerState => .scheduling,
            error.InvalidNumber, error.IntegerOverflow, error.FloatOverflow,
            error.InvalidAsciiRecord => .decode,
            else => .input,
        };
    }

    pub const Directive = enum {
        magic,
        format,
        element,
        property,
        comment,
        obj_info,
        end_header,
    };

    pub const Category = enum {
        /// `Options`/`Limits` validation failure.
        configuration,
        /// Header token or structure failure.
        header,
        /// Unknown or nonstandard encoding.
        encoding,
        /// Declared version not supported.
        version,
        /// Nonstandard scalar type declaration.
        scalar_type,
        /// Record failed to decode.
        record,
        /// Input ended prematurely.
        truncation,
        /// Configured resource limit exceeded.
        resource_limit,
        /// Concurrent execution failure.
        execution,
        memory,
        reader,
    };
};
