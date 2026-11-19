//! Small sequence-order helper for future completion tracking.
pub const ReorderState = struct {
    next_sequence: u64 = 0,

    pub fn accepts(self: *const ReorderState, sequence: u64) bool {
        return sequence == self.next_sequence;
    }
    pub fn delivered(self: *ReorderState) void {
        self.next_sequence += 1;
    }
};
