# Phase 11 M8 baseline corpus

The three `valid_*.ply` fixtures encode the **same** two logical records in
ASCII, binary little-endian, and binary big-endian PLY 1.0, including a
nonempty signed-16-bit list, an empty list, and an `f32` scalar following each
list. `invalid_list_type.ply` is a header-only negative fixture using a
floating-point count type, which must be rejected as `InvalidListCountType`.

These are checked-in, locally generated fixtures; they require no external
samples, network access, or third-party libraries. The fast deterministic
corpus test embeds the exact bytes. `std.testing.fuzz` has its own inline
Smith seeds, so it does *not* read these files as coverage-guided inputs.

Each future fuzz-discovered bug should receive a minimized fixture here and
an assertion that fails for the original behavior, recording the original
Smith seed, expected error/value, and affected invariant.
