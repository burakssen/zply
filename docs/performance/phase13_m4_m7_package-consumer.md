# Phase 13 M4–M7 — Package layout and standalone consumer

## Decision

The established package and module name is **`zply`**:

```zig
const zply = @import("zply");
```

`build.zig.zon` already names the package `zply`, and `build.zig` exports the
same module. Earlier comments and README snippets used `@import("ply")`;
those snippets were not valid for the package as built. New public examples,
the module documentation, and the standalone consumer use `zply` consistently.

The parser remains a source module. The build exports it with `b.addModule`;
there is intentionally no static or dynamic library artifact in the default
install step.

## Distribution layout

The manifest now includes `examples/` alongside the existing public source,
build metadata, documentation, and license. The repository retains tests,
benchmarks, and scripts because the current build graph exposes their named
validation steps. Package minimization is deferred until those optional steps
can be separated without leaving dangling source paths in the distributed
`build.zig`.

## Standalone integration gate

`tests/consumer/` is a deliberately separate Zig build root. Its
`build.zig.zon` depends on the repository through a local path and its
`build.zig` imports only the dependency's exported `zply` module. It does not
import `src/`, `tests/`, or any internal module by path.

Run it directly:

```sh
zig build test-consumer
```

or as part of the ordinary suite:

```sh
zig build test
```

The consumer parses an ASCII XYZ document, verifies header metadata, streams
typed `f32` columns, releases every batch, and checks the final record count.
It catches a wrong module name, omitted manifest dependency, or a build graph
that only works within this repository. A later release-candidate gate must
repeat the same test with the exact published archive and Zig content hash.

## Public examples

`zig build examples` compiles all examples. `zig build test-examples` executes
them against small deterministic embedded documents. The examples cover header
inspection, streaming record counting, XYZ bounds, list offsets, memory budget
inspection, unordered delivery metadata, and detailed initialization
diagnostics. Their fixed readers are intentionally self-contained; applications
replace them with their own caller-owned `std.Io.Reader` implementation.
