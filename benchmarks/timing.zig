//! Phase 12 M2: common monotonic interval validation for all benchmark scopes.
//! Callers obtain timestamps with std.Io.Clock.awake.now(io). Time creation of
//! fixtures outside the timed scopes.

pub fn elapsedNs(start: anytype, end: @TypeOf(start)) !i96 {
    const ns = start.durationTo(end).nanoseconds;
    if (ns <= 0) return error.InvalidMeasurement;
    return ns;
}
