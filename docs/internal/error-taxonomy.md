# Phase 11 M4 — Error taxonomy and recovery contract

## Scope

This milestone **does not** rename existing Zig error values, alter the public
`Parser.init`/`next` signatures, or change parser state transitions. `Diagnostic`
continues to report the **exact** error and its source location. The additive
`recovery` field expresses guidance, not an automatic permission to call `next`
again. This is deliberate: the same `ResourceLimitExceeded` can originate from
an input limit or from temporary admission pressure.

## Public diagnostic policy

| Example errors | Category | Recovery guidance | Meaning |
| --- | --- | --- | --- |
| `InvalidConfiguration` | configuration | terminal | Options are invalid; no source bytes consumed |
| `InvalidMagic`, `InvalidProperty`, `NumericOverflow` (header count) | header | terminal | Invalid header grammar or representability |
| `UnsupportedEncoding`, `UnsupportedVersion` | encoding / version | terminal | Format outside the supported profile |
| `InvalidScalarType`, `InvalidListCountType` | scalar_type | terminal | Invalid schema type |
| `InvalidNumber`, `NegativeListCount`, `InvalidBinaryRecord` | record | terminal | Invalid value or body structure |
| `TruncatedInput`, `TruncatedRecord`, `TruncatedListCount`, `TruncatedListPayload` | truncation | terminal | Physical EOF before declared body completes |
| `RecordTooLarge`, `ListTooLarge`, `HeaderTooLarge`, `TokenTooLong` | resource_limit | terminal | A specific configured limit was exceeded |
| `ResourceLimitExceeded` | resource_limit | context_dependent | May represent a permanent input/config limit **or** an admission failure |
| `MemoryPressure`, `BatchCapacityUnavailable` | memory | resource_pressure | May clear after leases are released or storage/task slots become available |
| `OutOfMemory` | memory | context_dependent | Underlying allocator failed; cannot infer retry safety from the code alone |
| `ReadFailed` | reader | terminal | Underlying read failure, **not** physical EOF |
| `InvalidProducerState`, `ConcurrentFailure` | execution | terminal | Invalid/failed parser execution state |

`recovery` is not a promise that retry succeeds. A retry is **permitted only
when the Parser is still `.ready` or `.reading`** and the relevant input staging
contract preserves the full next record. After `.failed`, another `next()` is
invalid even if an earlier diagnostic described memory pressure. The caller
may release held batches and retry *only* if its prior error was recoverable
according to the parser's documented state and failure path.

Initialization failure is terminal for the attempted `initDetailed` call:
there is no Parser instance to retry. The caller may correct options or
provide more resources and initialize a *new* Parser; it must not assume the
original Reader was rewound after a header error.

## Error precedence and reader position

* For binary lists, validate the count field exists, reject negative counts,
  apply configured limits, check arithmetic and capacity, then read payload.
* A structural truncation should not be silently reported as successful EOF.
* `ReadFailed` and `Truncated*` are separate outcomes. Do not replace one with
  the other when handling exceptions from caller-owned I/O.
* Successful parsing stops after the declared record counts, leaving any
  trailing bytes logically unread.
* Header `byte_offset` is document-relative, not an absolute file offset;
  the caller's Reader may buffer ahead. A failed parse does not rewind it.
* In ordered concurrent mode, an error discovered by lookahead may be deferred
  until earlier successfully admitted batches have been delivered. Phase 11
  M13 will test deterministic precedence across multiple simultaneous errors.

## Follow-up audit obligations

* M5–M7: establish a complete strict/compatibility grammar matrix, audit every
  resource-limit call site, and prove output capacities/offsets.
* M12–M14: prove recoverability or terminality at every failure boundary with
  reader, allocator, lease, task, and cancellation injection.
* Avoid a general `canRetry(error)` boolean; state and source context are
  necessary to make a sound retry decision.

Regression tests: `tests/error_taxonomy_test.zig` and the existing
`tests/diagnostics_test.zig`.
