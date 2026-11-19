# Phase 11 M15 — Regression corpus and CI gates

## Scope

This milestone adds an **immutable-input, deterministic corpus** and automated
cross-platform/release-profile checks. It does **not** alter the parser's public
API, parsing algorithms, scheduling, or memory accounting.

### Permanent fixtures

`tests/fixtures/regressions/` contains minimal, hand-authored PLY 1.0 samples.
The accompanying `README.md` records the expected outcome, encoding, failure
category, and the regression being exercised. None originate from external
projects, and none use random generation (seed: N/A).

`tests/phase11_regression_test.zig`:

- Replays valid XYZ+RGB and mixed face-list/camera documents in ASCII, binary
  little-endian, and binary big-endian formats.
- Independently checks decoded scalar bits, RGB values, signed zero, list
  items and offsets, record counts, and element boundaries.
- Varies non-seekable reader fragments and chunk sizes.
- Appends an extra trailer to valid fixtures during the test to verify
  declared-body completion without consuming unrelated bytes.
- Replays malformed magic, version, format duplication, list count types,
  numeric tokens, fixed-width truncation, list-count/payload truncation, and
  negative signed counts.
- Asserts the exact public error, structured diagnostic category, failed
  parser state, and inability to continue after terminal errors.
- Confirms every fixture has a corresponding expectation in the corpus index.

These fixtures preserve known **behavioral invariants**; they do not imply that
all cases were previously observed bugs. For a genuine discovered defect,
minimize the reproducer, add a fixture, document its seed/parameters and actual
bug history, and add the case to the executable table.

## Local validation matrix

From `zply/`:

```sh
zig build test-regression
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test-faults
zig build test-concurrency
zig build test-ownership-memory
```

Optional heavier release validation (not run on every regular test):

```sh
zig build test-stress -Doptimize=ReleaseSafe
zig build fuzz-phase11 --fuzz=1000
zig build fuzz-valid-ply --fuzz=1000
zig build fuzz-differential --fuzz=1000
zig build fuzz-metamorphic --fuzz=1000
```

`test-stress` aggregates the existing 3M/10M virtual binary-variable tests,
large ASCII streams, deterministic native scheduling tests and M14 ownership
checks. It does not create large fixture files on disk.

## CI

Repository-root `.github/workflows/zply-phase11.yml`:

- Pull requests and pushes: Debug, ReleaseSafe and ReleaseFast on Linux x86-64
  and the GitHub-hosted macOS runner; run `test`, `test-regression`, and
  regression-test source formatting verification.
- Weekly schedule and manual dispatch: additional ReleaseSafe stress, fault
  injection and bounded fuzz campaigns on Linux.
- Zig version: `0.17.1`, pinned to the version exercised in local M8–M14
  verification. The repository has a nested `zply/` build root.

The hosted macOS runner's exact architecture depends on GitHub runner image
selection; **Apple Silicon coverage still requires an explicit ARM64 runner
or a separately verified local run.** The CI matrix does not claim this gate.

Fuzzer findings need to be minimized and committed to the permanent corpus;
coverage is not a replacement for cross-platform correctness or stress tests.
Third-party interoperability fixtures remain future work pending documented
provenance and applicable licenses.

## Acceptance and limitations

- Every checked-in case must be deterministic and have an executable expected
  outcome; failing cases cannot be silently skipped.
- A parser crash, invalid error category, leaked batch, wrong value, or unexpected
  trailer read fails the regression suite.
- CI is defined but must pass on the actual GitHub runners before treating it
  as a release gate. No cross-platform runtime result is claimed by this patch.
- M16 will measure performance against pre-hardening baselines separately.
