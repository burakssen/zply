# Phase 11 / M1 — Parser invariant audit

**Source baseline:** `93b7117` (Phase 10 complete, Zig 0.17.1 used by the latest validated runs).
**Scope:** audit of existing source and test intent; **not** a new proof of safety or a fresh Zig test run.
**Status:** M1 inventory and ownership map complete. Items labelled `Partial` or `Gap` are obligations for subsequent Phase 11 milestones.

## How to use this register

- IDs are stable. Update the evidence and disposition whenever code or tests change; do not renumber existing IDs.
- **Existing** means the listed implementation/test visibly addresses the contract. It is not an assertion that the invariant holds for every input or platform.
- **Partial** means a relevant mechanism/test exists but some cases or an independent check are missing.
- **Gap** means the requested verification or API is not present in the audited revision.
- **Severity** describes what an invariant violation would represent: **Bug** (internal logic, lifetime or memory safety), **Invalid input** (must be rejected cleanly), **Resource** (must be bounded or reported), **Contract** (external ownership/reader requirements). Invariant violations are not automatically user errors.
- File locations are relative to `zply/`. A test is evidence of an exercised scenario, not an exhaustive proof.

## Input and reader invariants

| ID | Contract / validation point | Enforcing module | Existing evidence | State | Severity |
| --- | --- | --- | --- | --- | --- |
| INP-001 | Only the coordinating producer reads the borrowed input reader; tasks decode owned slices. Check before task creation and in decode entry points. | `src/parser.zig` (`startTask`, `startBinaryTask`, `startAsciiTask`), `src/input/producer.zig`, `src/execution/task.zig` | `tests/concurrent_pipeline_test.zig` — native concurrent decoding; `tests/reader_boundary_test.zig` — fragmented source | Existing | Bug |
| INP-002 | Header parsing ends at the first logical body byte; buffered prefetch is not extra logical consumption. | `src/format/header_reader.zig`, `src/format/header_parser.zig` | `tests/parser_init_test.zig` — body preservation / mid-stream offset; `tests/header_parser_test.zig` — immediate body bytes | Existing | Bug |
| INP-003 | A chunk contains complete records belonging to exactly one element. Check when staging and when decoding. | `src/input/producer.zig`, `src/input/binary_chunk_builder.zig`, `src/input/ascii_builder.zig`, `src/decode/binary/preflight.zig` | `tests/binary_variable_parser_test.zig` — fixed/variable/fixed transitions; `tests/ascii_concurrent_test.zig` — multi-element transitions | Existing | Bug |
| INP-004 | Successful declared records are emitted exactly once, with original element-local indices and monotonically assigned chunk sequences. | `src/input/producer.zig`, `src/input/binary_chunk_builder.zig`, `src/parser.zig` | `tests/binary_variable_hardening_test.zig` — identity in both delivery modes; `tests/concurrent_pipeline_test.zig` — 3M exact-once | Existing | Bug |
| INP-005 | Structural reads can be fragmented arbitrarily, including count prefixes and long lists; no seek/reopen is necessary. | `src/input/binary_variable.zig`, `src/input/ascii_record_reader.zig` | `tests/binary_variable_stream_test.zig` — fragmented count/payload; `tests/ascii_fragment_test.zig` — one-byte input | Existing | Bug |
| INP-006 | Recoverable memory pressure never loses a consumed partial record or rereads its prefix. | `src/input/binary_variable.zig`, `src/input/binary_chunk_builder.zig`, `src/parser.zig` | `tests/binary_variable_recovery_test.zig` — injected allocations and resume; `tests/ascii_concurrent_test.zig` — retained batch under pressure | Existing | Bug |
| INP-007 | Successful completion uses declared counts, not physical EOF; trailer is logically left unread. | `src/input/producer.zig`, `src/parser.zig` | `tests/streaming_binary_test.zig` — trailer; `tests/binary_variable_parser_test.zig` — trailer; `tests/ascii_concurrent_test.zig` — trailing data | Existing | Contract |
| INP-008 | A failed partial read never publishes an incomplete batch; EOF/truncation and genuine reader failures are distinguished. | `src/input/producer.zig`, `src/input/binary_variable.zig`, `src/parser.zig` | `tests/binary_variable_stream_test.zig` — EOF vs read failure; `tests/truncated_input_test.zig`; `tests/binary_variable_hardening_test.zig` | Existing | Invalid input |
| INP-009 | Every terminal error has a defined post-error reader-position contract, separating prefetch, logical consumption and partial physical progress. | `src/format/header_reader.zig`, `src/input/producer.zig`, `src/input/binary_variable.zig` | Several path-specific tests above; no uniform public table found | Partial | Contract |

## Header and schema invariants

| ID | Contract / validation point | Enforcing module | Existing evidence | State | Severity |
| --- | --- | --- | --- | --- | --- |
| SCH-001 | Every property belongs to one declared element; element/property order is preserved. | `src/format/header_builder.zig`, `src/format/header_parser.zig`, `src/format/layout.zig` | `tests/header_parser_test.zig` — vertex/face order; `tests/layout_test.zig` | Existing | Bug |
| SCH-002 | Canonical scalar widths and signedness are retained; compatibility aliases resolve only under the selected policy. | `src/format/types.zig`, `src/format/header_parser.zig` | `tests/types_test.zig`, `tests/header_parser_test.zig` — aliases/compatibility | Existing | Invalid input |
| SCH-003 | List count types must be integer; list item types retain declared scalar type. | `src/format/header_parser.zig`, `src/format/property.zig` | `tests/header_validation_test.zig` — float count rejection; `tests/header_parser_test.zig` — all count/item types | Existing | Invalid input |
| SCH-004 | A fixed offset is never advertised after a variable list; static byte widths and body sizes use checked arithmetic. | `src/format/layout.zig` (`compileSchema`) | `tests/layout_test.zig` — list followed by scalar, multi-list, size overflow | Existing | Bug |
| SCH-005 | Empty elements and nonempty zero-property elements remain representable and make finite logical progress without reading body bytes. | `src/format/layout.zig`, `src/input/producer.zig`, `src/parser.zig` | `tests/layout_test.zig`; `tests/batch_test.zig` — zero-property; `tests/ascii_matrix_test.zig` | Existing | Bug |
| SCH-006 | Structural header limits, duplicate policy, grammar, and strict/compatibility acceptance are applied before unbounded work. | `src/options.zig`, `src/format/header_reader.zig`, `src/format/header_builder.zig` | `tests/header_validation_test.zig` — limits/duplicates/invalid input; `tests/header_parser_test.zig` — compatibility | Partial | Invalid input / Resource |
| SCH-007 | A documented *complete* strict/compatibility policy covers unusual whitespace, numeric spellings, and nonstandard producer behavior across all three encodings. | `src/options.zig`, header/ASCII parsing modules | Existing tests cover selected behavior; no central compatibility matrix verified | Gap | Contract |

## Decoded batch invariants

| ID | Contract / validation point | Enforcing module | Existing evidence | State | Severity |
| --- | --- | --- | --- | --- | --- |
| BAT-001 | For a batch of N records, every scalar column exposes exactly N initialized typed values. | `src/batch/storage.zig`, `src/decode/record.zig`, `src/decode/ascii/record.zig` | `tests/batch_test.zig` — typed columns across boundaries; `tests/ascii_matrix_test.zig` | Existing | Bug |
| BAT-002 | List offsets contain N+1 positions, start at zero, are nondecreasing and end at the initialized value count. | `src/batch/storage.zig`, `src/decode/binary/preflight.zig`, `src/decode/ascii/preflight.zig` | `tests/binary_variable_decode_test.zig`; `tests/ascii_matrix_test.zig`; `tests/binary_variable_hardening_test.zig` | Existing | Bug |
| BAT-003 | Every list property's count/value cursor is independent and preserves the original item type and bit patterns. | `src/batch/storage.zig`, `src/decode/binary.zig` | `tests/binary_variable_decode_test.zig` — multiple lists/all item types/NaN; `tests/batch_test.zig` — float bits | Existing | Bug |
| BAT-004 | Decoders publish only fully initialized columns; a failure/cancellation discards partial output. | `src/execution/task.zig`, `src/batch/storage.zig`, `src/parser.zig` | `tests/binary_variable_final_test.zig` — mid-list cancellation; `tests/cancellation_test.zig`; `tests/batch_test.zig` — truncation | Existing | Bug |
| BAT-005 | An active batch lease prevents storage reuse; released slot generations reject stale aliases where supported. | `src/batch/storage.zig`, `src/input/pool.zig` | `tests/batch_test.zig` — held leases; `tests/ownership_pool_test.zig` — generation checks | Partial | Bug / Contract |
| BAT-006 | Copying a `Batch` value does **not** create a new independent lease; all leases must be released before `Parser.deinit()`. | `src/batch/storage.zig` (`Pool.destroy`), caller contract | `Pool.destroy` traps on still-leased slots; no complete public misuse/lifetime test matrix | Partial | Contract |

## Memory and resource invariants

| ID | Contract / validation point | Enforcing module | Existing evidence | State | Severity |
| --- | --- | --- | --- | --- | --- |
| MEM-001 | Accounted parser allocations plus reservations must stay within `Options.memory_budget` at every transition. | `src/memory/budget.zig`, `src/memory/control.zig`, `src/memory/allocator.zig` | `tests/budget_test.zig` — reservations/overlap; `tests/budget_integration_test.zig` — bootstrap to destruction | Existing | Bug / Resource |
| MEM-002 | Charge **capacity**, including idle buffers, column arrays, pool slots and growth overlap, not only initialized payload length. | `src/memory/allocator.zig`, `src/memory/reserved_allocator.zig`, `src/batch/storage.zig` | `tests/budget_test.zig` — realloc overlap; `docs/memory-audit.md` | Existing | Bug |
| MEM-003 | Reservation commitment and cancellation cannot double charge, leak, or spend another operation's reservation. | `src/memory/budget.zig`, `src/memory/reserved_allocator.zig` | `tests/budget_test.zig` — reservation operations, failure cleanup | Existing | Bug |
| MEM-004 | Memory admission precedes reader consumption; constrained output can split at full record boundaries and preserve staging. | `src/parser.zig`, `src/input/binary_chunk_builder.zig`, `src/batch/planner.zig` | `tests/budget_integration_test.zig`; `tests/binary_variable_recovery_test.zig`; `tests/binary_variable_hardening_test.zig` | Existing | Bug / Resource |
| MEM-005 | A single unsatisfiable record yields a bounded resource error rather than indefinite retry or silent budget overshoot. | `src/parser.zig`, `src/input/binary_boundary.zig` | `tests/binary_variable_stream_test.zig` — excessive count; `tests/binary_variable_hardening_test.zig` — oversized but admissible record | Partial | Resource |
| MEM-006 | Live/reserved counters reconcile with an **independently** instrumented backing allocator during concurrent failure, retained leases, and shutdown. | `src/memory/control.zig` and future test-only allocator | `memoryStats()` exposes counters; integration tests assert budget, but no comprehensive independent concurrent reconciliation verified | Gap | Bug |
| MEM-007 | Every producer/task/buffer allocation and task descriptor is budgeted; no unbounded CPU retry for pathological finite declarations. | `src/options.zig`, `src/parser.zig`, `src/input/*`, `src/execution/*` | `tests/budget_integration_test.zig`; bounded `max_outstanding_tasks` in parser; large-stream tests | Partial | Resource |

## Native concurrency and lifetime invariants

| ID | Contract / validation point | Enforcing module | Existing evidence | State | Severity |
| --- | --- | --- | --- | --- | --- |
| EXE-001 | Tasks reference stable heap-backed metadata, immutable staged input and exclusively owned output; a moving `Parser` does not invalidate work. | `src/parser.zig`, `src/execution/registry.zig`, `src/execution/task.zig`, `src/batch/storage.zig` | `tests/batch_test.zig` — moved parser; `tests/concurrent_pipeline_test.zig` | Existing | Bug |
| EXE-002 | Every submitted native future is joined or cancelled before raw/input/output/task resources are freed. | `src/parser.zig` (`cancelPending`, `deinit`), `src/execution/task.zig` | `tests/concurrent_pipeline_test.zig` — early destruction; `tests/fault_injection_test.zig` — active cancellation | Existing | Bug |
| EXE-003 | Ordered delivery respects global sequence, not completion order; unordered delivery preserves source identity. | `src/parser.zig` (`next`, `finishTask`), `src/execution/task.zig` | `tests/fault_injection_test.zig` — forced reverse completions; `tests/batch_test.zig` — unordered | Existing | Bug |
| EXE-004 | Completion and reordering metadata are bounded independently of completion rate, and accounted while pending. | `src/parser.zig` (`max_outstanding_tasks`), `src/execution/task.zig` (`CompletionQueue`) | `tests/fault_injection_test.zig` — notification failure; `tests/concurrent_pipeline_test.zig` | Existing | Bug / Resource |
| EXE-005 | Worker failures and read-ahead errors do not publish partial output; earlier valid ordered batches may still be delivered. | `src/parser.zig` (`deferred_error`, `finishTask`), `src/execution/task.zig` | `tests/concurrent_pipeline_test.zig` — read-ahead failure; `tests/fault_injection_test.zig` — later ASCII error | Partial | Bug |
| EXE-006 | If multiple tasks fail, ordered mode deterministically selects the earliest **logical** failing sequence, independent of completion order. | `src/parser.zig`, `src/execution/task.zig` | Forced completion ordering tests exist, but no two-failing-tasks error-precedence test verified | Gap | Bug |
| EXE-007 | Cancellation checks inside long lists, during task joins and before publication; parser shutdown never races unfinished task storage. | `src/execution/task.zig`, `src/parser.zig` | `tests/binary_variable_final_test.zig` — mid-list cancellation; `tests/fault_injection_test.zig` — active decode/cancel | Partial | Bug |

## Diagnostics and error-boundary register

| ID | Contract / validation point | Enforcing module | Existing evidence | State | Severity |
| --- | --- | --- | --- | --- | --- |
| DIA-001 | Header, schema, input, preflight, decode, scheduling and memory errors have distinct, documented public categories and retry status. | `src/errors.zig`, `src/parser.zig` | `tests/header_validation_test.zig`; `tests/binary_variable_stream_test.zig` | Partial | Contract |
| DIA-002 | Diagnostics are fixed-size stable values, never borrowed from reusable input buffers or task stacks. | `src/errors.zig` (`Diagnostic`) | `tests/api_test.zig` — diagnostic shape; `tests/ascii_test.zig` — error offsets | Partial | Bug |
| DIA-003 | Both header-initialization errors and body errors have a single optional diagnostic API, without changing `Parser.init()` or required consumer usage. | **Future** `initDetailed()` / `lastDiagnostic()`; existing `asciiDiagnostic()` and `binaryDiagnostic()` in `src/parser.zig` | Existing encoding-specific accessors; no init diagnostic result channel | Gap | Contract |
| DIA-004 | Error byte offsets distinguish initial document position, body-relative offsets, and logical read vs prefetch. | `src/errors.zig`, `src/parser.zig`, `src/input/binary_variable.zig` | `tests/parser_init_test.zig` — nonzero start; `tests/ascii_test.zig` — token offsets | Partial | Bug / Contract |
| DIA-005 | A completed batch stays owned and usable after a later error until the caller releases it. | `src/batch/storage.zig`, `src/parser.zig` | `tests/binary_variable_hardening_test.zig` — earlier batches before truncation; `tests/fault_injection_test.zig` | Existing | Contract |

## Validation boundaries and ownership flow

The following is the current intended dataflow, **not** a proposal to add another scheduler or another public parser API:

1. **Header input:** `format/header_reader.zig` obtains bounded lines; `header_parser.zig` and `header_builder.zig` validate grammar, names, declaration limits, and construct owned metadata. Unknown/unbounded input remains untrusted.
2. **Schema compilation:** `format/layout.zig` records checked widths and binary property operations. Only a compiled layout may be passed to record scanners; offsets after a list remain unresolved.
3. **Chunk production:** `input/producer.zig` (fixed), `input/ascii_*` (ASCII), and `input/binary_variable.zig` + `binary_chunk_builder.zig` (variable) own incremental reader progress and expose only complete record slices and boundaries for decoding.
4. **Preflight/admission:** `batch/planner.zig`, `decode/ascii/preflight.zig`, `decode/binary/preflight.zig`, and `memory/*` validate record ranges/output sizes and reserve capacity before worker publication. The source must not be read again to retry admitted/staged records.
5. **Decode/publication:** `execution/task.zig` decodes against independently owned raw and output storage. `batch/storage.zig` publishes only successfully initialized views and leases them until explicitly released.

**Trust boundary rule:** A function that accepts arbitrary byte slices must bounds-check them. A hot kernel can rely on validated internal input *only if construction and lifetime are restricted to the validating path*. Phase 11 M5–M7 should verify that these trust assumptions remain true at each call site.

## Risk register / work to carry forward

| Priority | Obligation | Next milestone | Evidence needed |
| --- | --- | --- | --- |
| P0 | Unified stable diagnostic taxonomy; distinguish init failure vs body failure without borrowed pointers or allocations on errors (`DIA-001`..`DIA-004`). | M2–M4 | Exact malformed-header and malformed-body assertions; no caller API break |
| P0 | Deterministic earliest-logical-error policy when **multiple** worker tasks fail (`EXE-006`). | M13 | Forced out-of-order two-error test, single error published, all tasks joined |
| P0 | Independent allocator reconciliation of live/reserved/capacity during failures and leases (`MEM-006`). | M12/M14 | Instrumented backing allocator agrees with `memoryStats()` within documented overhead scope |
| P1 | Complete strict/compatibility grammar matrix, including one-line-per-record ASCII profile (`SCH-006`/`SCH-007`). | M5 | Explicit accepted/rejected syntax tests and documentation |
| P1 | Review all untrusted `usize`/`u64` conversions, offset math, and zero-width loops (`SCH-004`, `MEM-005`, `MEM-007`). | M6–M7 | Arithmetic/termination tests, resource-limit distinctions |
| P1 | Cross-stage cancellation matrix and batch misuse policy (`EXE-007`, `BAT-005`/`BAT-006`). | M13–M14 | Forced checkpoints, stale generation and retained-lease coverage |
| P1 | Full-parser fuzzing / structured generated corpus across ASCII, binary LE, binary BE. | M8–M11 | Corpus replay, independent expected records, metamorphic invariance |
| P2 | External real-file interoperability plus release CI, performance delta. | M15–M16 | Licensed fixtures, reference reader comparisons, baseline benchmarks |

## Baseline validation commands and limits

From the `zply/` directory:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test-ascii-large -Doptimize=ReleaseFast
zig build test-binary-variable-large -Doptimize=ReleaseFast
zig build bench-binary-variable -Doptimize=ReleaseFast
```

Existing optional fuzz targets use `zig build fuzz-binary-variable ... --fuzz=100K` and are not a substitute for whole-parser fuzzing. The Phase 10 `bench-binary-variable-matrix` is opt-in and records 64/256/1024 KiB chunks with 16/64/256 MiB budgets; it does not exercise all failure paths.

The current `memoryStats()` describes **allocator-visible parser-owned allocation capacity and reservations**, not process RSS, caller reader buffers, or allocator-internal bookkeeping. Do not label it a whole-process memory bound. The supplied `std.Io` runtime also owns its own resources outside the parser's budget.

**M1 exit criterion:** each high-impact invariant has a module owner and existing or planned tests; unresolved cases remain explicitly marked for the next milestone. No source-code changes or new behavior are implied by this document.
