# Phase 11 M7 — Resource limits, memory budget and logical EOF

This milestone strengthens the public parser's **terminal vs recoverable**
resource error contract. It does not alter `Parser.init`, `Parser.next`, the
reader-borrowing policy, or native `std.Io` task scheduling.

## Limits and enforcement boundaries

| Limit | Enforcement |
| --- | --- |
| `max_header_bytes` and `max_header_line_bytes` | Bounded header line reader |
| `max_elements`, `max_properties_per_element`, `max_total_properties` | Header builder |
| `max_ascii_record_bytes` | ASCII record reader, before appending beyond the cap |
| `max_ascii_token_bytes`, `max_list_items_per_record` | ASCII preflight/decoder |
| `max_record_bytes` | Fixed binary chunk planner and binary-variable scanner |
| `max_list_items_per_record` | Binary-variable scanner before item byte multiplication |
| `memory_budget` | Parser-owned accounting allocator and task reservations |
| In-flight task count | Internal fixed completion/task table; **not** a worker setting |

The configured limits are application resource restrictions, not evidence
that an otherwise valid PLY file is malformed. Checked arithmetic precedes
untrusted index/slice operations. The accounted budget measures parser-owned
allocator-requested capacity; it excludes the caller's Reader, Io runtime,
allocator-private bookkeeping and external consumer allocations. It does **not**
claim a bound on whole-process RSS.

## Error state and retry policy

* Header/resource syntax errors during `initDetailed` end that initialization
  attempt; its reader may already have advanced.
* A binary **fixed** record wider than `max_record_bytes` is permanently
  unparseable with the current options. `next` returns `RecordTooLarge` and
  enters `.failed` without reading body bytes.
* If binary admission cannot fit the minimum record and there are **no**
  outstanding parser tasks or consumer-held batches, `ResourceLimitExceeded`
  is terminal for that parser. Neither waiting nor repeating `next` can
  increase its fixed memory budget.
* Admission pressure while batches/tasks are still active can remain
  recoverable. Release batches and retry only while the parser state remains
  `.ready`/`.reading`; staged input and source-position contracts still apply.
* An underlying `OutOfMemory` is not automatically a configured-limit error.
  The underlying allocator can fail independently of the parser's budget.
* `RecordTooLarge`, `ListTooLarge` and truncation are not equivalent to
  `MemoryPressure`. No terminal failure can be retried via `next`.

## Successful completion and trailing data

Success means exactly the declared number of supported records have been
published. The parser does **not** require physical EOF and does not read
or validate bytes after the declared body by default. The reader may have
prefetched into its own buffer; its *logical* position is what matters.

* A document with zero declared records completes without a body read.
* Bytes following the declared body stay available through the same borrowed
  reader, for ASCII, fixed binary and variable binary encodings.
* Physical EOF before declared body completion (`TruncatedBody`) is
  classified as `.truncation`, while an underlying reader failure
  (`ReadFailed`) is classified as `.reader`. Neither publishes a partial
  record.
* Failed reads can consume a prefix of a record; the parser does not
  promise source rewind after a terminal failure.

Regression coverage: `tests/phase11_resource_eof_test.zig`. Deeper fault
injection for allocator failures, retained leases and active futures remains
part of the later Phase 11 milestones.
