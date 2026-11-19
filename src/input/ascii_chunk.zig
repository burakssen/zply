//! Location metadata for an ASCII record or chunk; independent of I/O.
pub const Chunk = struct {
    element_index: usize,
    first_record: u64,
    record_count: usize,
    sequence: u64,
    first_body_byte_offset: u64,
    consumed_body_bytes: u64,
};
