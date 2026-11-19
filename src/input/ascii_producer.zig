//! Sequential ASCII progress, including a complete staged record on pressure.
pub const State = struct {
    /// True when the last complete line was read but has not been published.
    pending_record: bool = false,
    /// Source progress is tracked separately by ascii_record_reader.Reader.
    /// Logical progress is committed only when the batch is published.
    batches: u64 = 0,
};
