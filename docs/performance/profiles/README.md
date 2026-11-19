# Phase 12 profile notes

Store profiler artifacts outside source control when they are large, and retain
one small Markdown note per profiling experiment here. Do not claim timing
numbers without the raw benchmark CSV captured by `scripts/capture_phase12.py`.

```text
Experiment ID: PERF-###
Commit:
Zig version / optimization:
Platform / CPU:
Profiler and command:
Workload / consumer / chunk / memory budget:
Top sampled functions:
Observation:
Hypothesis:
Candidate change:
Validation capture:
Decision: keep | revise | revert
```

Stage and task durations may overlap. Record pipeline wall time separately from
aggregate task execution time; never add them together as a latency total.
