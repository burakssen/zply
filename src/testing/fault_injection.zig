//! Internal, opt-in fault-injection seam for deterministic Phase 7 tests.
//!
//! The public Parser.Options API remains unchanged. Production code supplies
//! null and never invokes callbacks; test callbacks must be thread safe and
//! must not access or move the parser while a worker is using its buffers.
//!
//! Hook callbacks are synchronous and may block the decoder on test-owned
//! atomics. This is intentional: tests can force exact completion orders
//! without sleeps or probabilistic race timing.
/// Parser-coordinator checkpoints immediately before allocation-bearing ASCII
/// admission operations. The task registry itself is fixed-capacity: task
/// registration does not allocate for every decode task.
pub const AsciiAdmissionPoint = enum {
    output_pool_create,
    task_registry_create,
    completion_state_create,
    record_scratch,
    stage_raw_growth,
    stage_boundary_growth,
    preflight_totals,
    raw_copy,
    boundary_copy,
    output_storage,
};

pub const Hooks = struct {
    context: *anyopaque,
    /// Coordinator-only test hook. Runs just before the allocation stage;
    /// a test can arm its backing FailingAllocator here. No hook is called
    /// by production builds, and no worker calls this callback.
    ascii_admission_point: ?*const fn (context: *anyopaque, point: AsciiAdmissionPoint) void = null,
    /// Runs after 4,096 decoded binary records or 1,024 decoded ASCII
    /// records, before that worker checks cancellation again.
    checkpoint: ?*const fn (context: *anyopaque, sequence: u64, decoded_records: usize) void = null,
    /// Runs within a large ASCII or binary list after a multiple of 4,096 items
    /// has been decoded, before the cooperative cancellation check.
    list_item_checkpoint: ?*const fn (context: *anyopaque, sequence: u64, decoded_items: usize) void = null,
    /// Inject a deterministic decoder error for a chosen task sequence.
    /// Invoked on the worker after it enters `running` but before writing
    /// output. Test builds only; null in production. The ordinary failure
    /// recording, notification and cancellation paths still run.
    decode_failure: ?*const fn (context: *anyopaque, sequence: u64) ?anyerror = null,
    /// Runs after decoding finishes but before posting a completion.
    before_notify: ?*const fn (context: *anyopaque, sequence: u64) void = null,
    /// Runs only after a completion has been successfully posted (or after
    /// the notification-failure handler has run).
    after_notify: ?*const fn (context: *anyopaque, sequence: u64) void = null,
    /// Simulates failure of the completion queue's put operation. This calls
    /// the *same* notification error handler used for a real put failure.
    fail_notification: ?*const fn (context: *anyopaque, sequence: u64) bool = null,
    /// Signals a *real* producer/admission error to the test controller so
    /// gated outstanding workers may be released before their join.
    admission_failure: ?*const fn (context: *anyopaque, err: anyerror) void = null,
    /// Called after cancellation was requested for every pending task,
    /// before futures are joined. Allows test-held workers to resume and
    /// observe their cancellation flags without timing races.
    after_cancel_signal: ?*const fn (context: *anyopaque) void = null,
    /// Prevent test-only gates from hanging if a constrained executor
    /// rejects guaranteed concurrency and the parser must fall back inline.
    submission_rejected: ?*const fn (context: *anyopaque, sequence: u64) void = null,
};
