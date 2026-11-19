# Phase 12 M4 — Reproducible baseline capture

## Scope

M4 records benchmark evidence; it does **not** claim a performance result in
source control. A capture is valid only for the exact generated workload,
consumer, configuration, compiler, and machine recorded beside it.

The `validation` consumer is the correctness baseline. It validates every
decoded scalar and list item. Run a second `minimal` capture only when
isolating parser throughput from consumer validation cost.

## Capture protocol

On an otherwise idle target machine, first capture a full validation matrix:

```sh
python3 scripts/capture_phase12.py results/phase12-validation.csv \
  --require-full-matrix -- \
  zig build bench-phase12 -Doptimize=ReleaseFast -- --consumer=validation
```

Then capture the same matrix with the minimal consumer when measuring parser
throughput:

```sh
python3 scripts/capture_phase12.py results/phase12-minimal.csv \
  --require-full-matrix -- \
  zig build bench-phase12 -Doptimize=ReleaseFast -- --consumer=minimal
```

Each command preserves raw benchmark stderr as CSV and writes a neighbouring
JSON manifest. The manifest records the Git revision and worktree state, Zig
version, OS/architecture/CPU model, core configuration, total RAM, exact
command, optimization mode, executor and input-source configuration, capture
SHA-256, fixture identity hash, workload/mode pairs, and consumer mode.

Do not compare `validation` against `minimal`, different chunk or budget
settings, or captures from a different machine/compiler. Keep the JSON and CSV
together. Large captures are intentionally operator-run rather than generated
by ordinary functional CI.

## Review comparison

Compare a candidate with a matching baseline using body time by default:

```sh
python3 scripts/compare_phase12.py \
  results/phase12-validation-baseline.csv \
  results/phase12-validation-candidate.csv \
  --require-full-matrix
```

Use `--timing-scope=lifecycle` to review initialization and teardown as well.
The comparator rejects mismatched workload configuration, fixture digest, or
consumer digest. It flags median latency growth above 10% and parser-peak
growth above 10% by default; those are review thresholds, not a substitute for
repeated measurements on controlled hardware.
