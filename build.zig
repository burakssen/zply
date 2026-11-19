const std = @import("std");

const test_files = [_][]const u8{
    "types_test.zig",
    "options_test.zig",
    "ownership_test.zig",
    "api_test.zig",
    "header_reader_test.zig",
    "header_parser_test.zig",
    "header_validation_test.zig",
    "layout_test.zig",
    "binary_list_count_test.zig",
    "binary_boundary_test.zig",
    "binary_variable_stream_test.zig",
    "binary_chunk_builder_test.zig",
    "binary_variable_decode_test.zig",
    "binary_variable_parser_test.zig",
    "binary_variable_adversarial_test.zig",
    "binary_variable_hardening_test.zig",
    "binary_variable_recovery_test.zig",
    "binary_variable_final_test.zig",
    "parser_init_test.zig",
    "diagnostics_test.zig",
    "error_taxonomy_test.zig",
    "phase11_header_numeric_test.zig",
    "phase11_numeric_stream_test.zig",
    "phase11_binary_list_validation_test.zig",
    "phase11_resource_eof_test.zig",
    "fuzz/phase11_fuzz_test.zig",
    "property/document_generator_test.zig",
    "property/mutation_differential_test.zig",
    "property/metamorphic_test.zig",
    "phase11_faults_test.zig",
    "phase11_concurrency_test.zig",
    "phase11_ownership_memory_test.zig",
    "phase11_regression_test.zig",
    "decode_scalar_test.zig",
    "decode_endian_test.zig",
    "decode_record_test.zig",
    "decode_range_test.zig",
    "decode_invalid_test.zig",
    "producer_test.zig",
    "chunk_planner_test.zig",
    "streaming_binary_test.zig",
    "element_transition_test.zig",
    "truncated_input_test.zig",
    "reader_boundary_test.zig",
    "streaming_memory_test.zig",
    "batch_test.zig",
    "budget_test.zig",
    "budget_integration_test.zig",
    "execution_test.zig",
    "ownership_pool_test.zig",
    "cancellation_test.zig",
    "concurrent_pipeline_test.zig",
    "fault_injection_test.zig",
    "ascii_test.zig",
    "ascii_fragment_test.zig",
    "ascii_matrix_test.zig",
    "ascii_concurrent_test.zig",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The reusable library module. Consumers may add it under any name
    // (e.g. `b.dependency(...)` + `mod.addImport("ply", ...)`) and then
    // `@import("ply")`.
    const zply_mod = b.addModule("zply", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    // Internal declarations for the library's own test suites only: the
    // bounded line reader, the header parser/builder, and the layout
    // compiler. Not part of the public API surface; never imported by
    // root.zig.
    const internals_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/internals.zig"),
    });

    const test_step = b.step("test", "Run unit and integration tests");

    // Tests declared inside the library's own sources.
    const lib_tests = b.addTest(.{ .root_module = zply_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Reader doubles live at tests/, outside the tests/property module root.
    // Make them a shared named module rather than importing with `../`.
    const m11_support_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/streaming_support.zig"),
    });
    m11_support_mod.addImport("zply_internals", internals_mod);

    // Test suites under tests/, each importing the module (and the
    // internals module, for suites that exercise internal units directly).
    inline for (test_files) |test_file| {
        const test_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/" ++ test_file),
        });
        test_mod.addImport("zply", zply_mod);
        test_mod.addImport("zply_internals", internals_mod);
        if (comptime std.mem.eql(u8, test_file, "property/metamorphic_test.zig")) {
            test_mod.addImport("streaming_support", m11_support_mod);
        }

        const test_compile = b.addTest(.{ .root_module = test_mod });
        const run_test = b.addRunArtifact(test_compile);
        test_step.dependOn(&run_test.step);
    }

    // Optional, expensive Phase 8 coverage. Keep multi-million-record tests
    // out of the default `zig build test` path. The virtual input Reader
    // generates each record on demand, without full-file allocations.
    const ascii_large_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/ascii_large_test.zig"),
    });
    ascii_large_mod.addImport("zply", zply_mod);
    const ascii_large_tests = b.addTest(.{ .root_module = ascii_large_mod });
    const run_ascii_large_tests = b.addRunArtifact(ascii_large_tests);
    const ascii_large_step = b.step("test-ascii-large", "Run Phase 8 multi-million-record ASCII correctness tests");
    ascii_large_step.dependOn(&run_ascii_large_tests.step);

    // Opt-in large binary-variable regression: virtual, non-seekable input
    // with 3M and 10M variable-width list records under a 16 MiB parser cap.
    // Kept outside the default `zig build test` path.
    const binary_large_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/binary_variable_large_test.zig"),
    });
    binary_large_mod.addImport("zply_internals", internals_mod);
    const binary_large_tests = b.addTest(.{ .root_module = binary_large_mod });
    const run_binary_large_tests = b.addRunArtifact(binary_large_tests);
    const binary_large_step = b.step("test-binary-variable-large", "Validate 3M and 10M non-seekable binary list records");
    binary_large_step.dependOn(&run_binary_large_tests.step);

    // Opt-in coverage-guided Zig 0.17.1 fuzzing of binary variable records.
    // The same tests replay their inline seed corpus in normal `zig build test`;
    // use --fuzz=N on this isolated step to discover new paths. The filter
    // can select `raw` or `structured` without running unrelated tests.
    const binary_fuzz_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/binary_variable_final_test.zig"),
    });
    binary_fuzz_mod.addImport("zply_internals", internals_mod);
    const binary_fuzz_filter = b.option([]const u8, "fuzz-filter", "Binary-variable fuzz target filter (raw or structured)") orelse "Phase 10 fuzz";
    const binary_fuzz_tests = b.addTest(.{
        .root_module = binary_fuzz_mod,
        .filters = &.{binary_fuzz_filter},
    });
    const binary_fuzz_step = b.step("fuzz-binary-variable", "Run coverage-guided binary-variable structural and streaming fuzz targets");
    binary_fuzz_step.dependOn(&b.addRunArtifact(binary_fuzz_tests).step);

    // Phase 11 M8: bounded header, numeric, valid-document, and body-mutation
    // fuzz targets. Ordinary `zig build test` replays only inline corpus seeds;
    // the isolated step accepts `--fuzz=N` for coverage-guided discovery.
    // Use one module universe to avoid Zig 0.17's duplicate-source ownership
    // error (zply and zply_internals share implementation files).
    const phase11_fuzz_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/fuzz/phase11_fuzz_test.zig"),
    });
    phase11_fuzz_mod.addImport("zply_internals", internals_mod);
    const phase11_fuzz_filter = b.option([]const u8, "phase11-fuzz-filter", "Phase 11 fuzz target filter: header, numeric, valid, or mutation") orelse "M8 fuzz";
    const phase11_fuzz_tests = b.addTest(.{
        .root_module = phase11_fuzz_mod,
        .filters = &.{phase11_fuzz_filter},
    });
    const phase11_fuzz_step = b.step("fuzz-phase11", "Coverage-guided Phase 11 header/numeric/document/mutation fuzzing");
    phase11_fuzz_step.dependOn(&b.addRunArtifact(phase11_fuzz_tests).step);

    // Phase 11 M9: generated multi-element, multi-type PLY documents with an
    // independent reference model. Kept in an isolated fuzz step so --fuzz=N
    // selects this target instead of another Phase 11 fuzz test.
    const m9_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/property/document_generator_test.zig"),
    });
    m9_mod.addImport("zply_internals", internals_mod);
    const m9_tests = b.addTest(.{
        .root_module = m9_mod,
        .filters = &.{"M9 fuzz independently generated"},
    });
    const m9_step = b.step("fuzz-valid-ply", "Coverage-guided valid PLY schema and record generator fuzzing");
    m9_step.dependOn(&b.addRunArtifact(m9_tests).step);

    // Phase 11 M10: standalone byte-level reference decoder and mutation
    // campaign. Only the internal module is imported to keep a single source
    // ownership tree under Zig 0.17.1.
    const m10_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/property/mutation_differential_test.zig"),
    });
    m10_mod.addImport("zply_internals", internals_mod);
    const m10_tests = b.addTest(.{
        .root_module = m10_mod,
        .filters = &.{"M10 fuzz differential byte mutations"},
    });
    const m10_step = b.step("fuzz-differential", "Coverage-guided Phase 11 M10 mutation and reference-decoder comparison");
    m10_step.dependOn(&b.addRunArtifact(m10_tests).step);

    // Phase 11 M11: isolated metamorphic fuzz campaign. Only one fuzz test
    // participates in --fuzz=N; deterministic cases run in `zig build test`.
    const m11_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/property/metamorphic_test.zig"),
    });
    m11_mod.addImport("zply_internals", internals_mod);
    m11_mod.addImport("streaming_support", m11_support_mod);
    const m11_tests = b.addTest(.{
        .root_module = m11_mod,
        .filters = &.{"M11 fuzz metamorphic"},
    });
    const m11_step = b.step("fuzz-metamorphic", "Coverage-guided Phase 11 M11 reader/budget/chunk metamorphic checks");
    m11_step.dependOn(&b.addRunArtifact(m11_tests).step);

    // Phase 11 M12: deterministic injection of non-seekable reader failures
    // and allocator failures. The same tests run under `zig build test` and
    // independently under `zig build test-faults`.
    const m12_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/phase11_faults_test.zig"),
    });
    m12_mod.addImport("zply_internals", internals_mod);
    const m12_tests = b.addTest(.{ .root_module = m12_mod });
    const m12_step = b.step("test-faults", "Run Phase 11 M12 reader and allocator fault-injection tests");
    m12_step.dependOn(&b.addRunArtifact(m12_tests).step);

    // Phase 11 M13: deterministic native task ordering, earliest-error
    // precedence and cancellation under pending work. Also part of `test`.
    const m13_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/phase11_concurrency_test.zig"),
    });
    m13_mod.addImport("zply_internals", internals_mod);
    const m13_tests = b.addTest(.{ .root_module = m13_mod });
    const m13_step = b.step("test-concurrency", "Run Phase 11 M13 deterministic native concurrency and cancellation tests");
    m13_step.dependOn(&b.addRunArtifact(m13_tests).step);

    // Phase 11 M14: generation-checked batch ownership, independent backing
    // allocator instrumentation and multi-budget retention/reuse tests.
    const m14_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/phase11_ownership_memory_test.zig"),
    });
    m14_mod.addImport("zply_internals", internals_mod);
    const m14_tests = b.addTest(.{ .root_module = m14_mod });
    const m14_step = b.step("test-ownership-memory", "Run Phase 11 M14 batch ownership and independently audited memory tests");
    m14_step.dependOn(&b.addRunArtifact(m14_tests).step);

    // Phase 11 M15: small, permanent hand-authored PLY fixtures, including
    // both endian formats, mixed properties, malformed headers and truncated
    // bodies. The same tests are included in the default test matrix.
    const m15_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/phase11_regression_test.zig"),
    });
    m15_mod.addImport("zply_internals", internals_mod);
    const m15_tests = b.addTest(.{ .root_module = m15_mod });
    const m15_step = b.step("test-regression", "Replay the permanent Phase 11 PLY regression fixtures");
    m15_step.dependOn(&b.addRunArtifact(m15_tests).step);

    // Expensive but deterministic stress coverage is deliberately opt-in.
    // CI release gates can run it independently of ordinary pull requests.
    const stress_step = b.step("test-stress", "Run large ASCII/binary streams and concurrent ownership stress tests");
    stress_step.dependOn(&run_ascii_large_tests.step);
    stress_step.dependOn(&run_binary_large_tests.step);
    stress_step.dependOn(m13_step);
    stress_step.dependOn(m14_step);

    // Panic probes run in child processes. Their custom handler distinguishes
    // the expected lease violation from all other panics and setup failures.
    const lease_probe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/lease_panic_probe.zig"),
    });
    lease_probe_mod.addImport("zply", zply_mod);
    const lease_probe = b.addExecutable(.{ .name = "lease_panic_probe", .root_module = lease_probe_mod });
    inline for (.{ "stale-release", "stale-access", "active-deinit", "control" }) |mode| {
        const run_probe = b.addRunArtifact(lease_probe);
        run_probe.addArg(mode);
        run_probe.expectExitCode(if (std.mem.eql(u8, mode, "control")) 0 else 86);
        test_step.dependOn(&run_probe.step);
        m14_step.dependOn(&run_probe.step);
    }

    // Phase 11 M16: cross-encoding warm-memory performance verification.
    // Measures the same deterministic input under sequential, native ordered,
    // native unordered, and small-chunk execution. Emits versioned CSV rows
    // to stderr for scripts/compare_phase11.py (capture with 2> file.csv).
    const m16_perf_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("benchmarks/phase11_performance.zig"),
    });
    m16_perf_mod.addImport("zply", zply_mod);
    const m16_perf_exe = b.addExecutable(.{ .name = "phase11_performance_bench", .root_module = m16_perf_mod });
    const m16_perf_step = b.step("bench-phase11", "Run Phase 11 M16 verified, cross-encoding performance matrix (CSV)");
    m16_perf_step.dependOn(&b.addRunArtifact(m16_perf_exe).step);

    // In-memory decode benchmarks (Phase 3): run with
    //   zig build bench -Doptimize=ReleaseFast
    const bench_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("benchmarks/binary_decode.zig"),
    });
    bench_mod.addImport("zply", zply_mod);
    const bench_exe = b.addExecutable(.{
        .name = "binary_decode_bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run in-memory decode benchmarks");
    bench_step.dependOn(&run_bench.step);

    const streaming_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("benchmarks/streaming.zig"),
    });
    streaming_mod.addImport("zply_internals", internals_mod);
    const streaming_exe = b.addExecutable(.{
        .name = "streaming_bench",
        .root_module = streaming_mod,
    });
    const streaming_run = b.addRunArtifact(streaming_exe);
    const streaming_step = b.step("bench-streaming", "Run warm-memory streaming benchmarks");
    streaming_step.dependOn(&streaming_run.step);

    const columns_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("benchmarks/columns.zig"),
    });
    columns_mod.addImport("zply_internals", internals_mod);
    const columns_exe = b.addExecutable(.{ .name = "column_bench", .root_module = columns_mod });
    const columns_run = b.addRunArtifact(columns_exe);
    const columns_step = b.step("bench-columns", "Compare record and column decoding");
    columns_step.dependOn(&columns_run.step);

    const concurrent_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("benchmarks/concurrent_decode.zig"),
    });
    concurrent_mod.addImport("zply", zply_mod);
    const concurrent_exe = b.addExecutable(.{ .name = "concurrent_decode_bench", .root_module = concurrent_mod });
    const concurrent_run = b.addRunArtifact(concurrent_exe);
    const concurrent_step = b.step("bench-concurrent", "Run native Io concurrent decode benchmark");
    concurrent_step.dependOn(&concurrent_run.step);
    const ascii_parallel_mod = b.createModule(.{
        .target = target, .optimize = optimize,
        .root_source_file = b.path("benchmarks/ascii_concurrent.zig"),
    });
    ascii_parallel_mod.addImport("zply", zply_mod);
    const ascii_parallel_exe = b.addExecutable(.{ .name = "ascii_concurrent_bench", .root_module = ascii_parallel_mod });
    const ascii_parallel_run = b.addRunArtifact(ascii_parallel_exe);
    const ascii_parallel_step = b.step("bench-ascii-concurrent", "Benchmark native Io concurrent ASCII scalar and list decoding");
    ascii_parallel_step.dependOn(&ascii_parallel_run.step);

    const binary_variable_bench_mod = b.createModule(.{
        .target = target, .optimize = optimize,
        .root_source_file = b.path("benchmarks/binary_variable_pipeline.zig"),
    });
    // The combined structural/Parser benchmark must use a single module
    // tree: both zply and zply_internals own files such as errors.zig.
    binary_variable_bench_mod.addImport("zply_internals", internals_mod);
    const binary_variable_bench_exe = b.addExecutable(.{
        .name = "binary_variable_pipeline_bench", .root_module = binary_variable_bench_mod,
    });
    const binary_variable_bench_run = b.addRunArtifact(binary_variable_bench_exe);
    const binary_variable_bench_step = b.step("bench-binary-variable", "Benchmark structural scanning and end-to-end binary variable lists");
    binary_variable_bench_step.dependOn(&binary_variable_bench_run.step);

    // Opt-in Phase 10 performance matrix: fixed fixtures, varied chunk size,
    // budget and native Io delivery mode. Kept separate from the quick bench.
    const binary_matrix_mod = b.createModule(.{
        .target = target, .optimize = optimize,
        .root_source_file = b.path("benchmarks/binary_variable_matrix.zig"),
    });
    binary_matrix_mod.addImport("zply_internals", internals_mod);
    const binary_matrix_exe = b.addExecutable(.{
        .name = "binary_variable_matrix_bench", .root_module = binary_matrix_mod,
    });
    const binary_matrix_run = b.addRunArtifact(binary_matrix_exe);
    const binary_matrix_step = b.step("bench-binary-variable-matrix", "Compare binary-list chunk sizes, budgets and native delivery modes");
    binary_matrix_step.dependOn(&binary_matrix_run.step);

    const ascii_mod = b.createModule(.{
        .target = target, .optimize = optimize,
        .root_source_file = b.path("benchmarks/ascii_streaming.zig"),
    });
    ascii_mod.addImport("zply", zply_mod);
    const ascii_exe = b.addExecutable(.{ .name = "ascii_streaming_bench", .root_module = ascii_mod });
    const ascii_run = b.addRunArtifact(ascii_exe);
    const ascii_step = b.step("bench-ascii", "Phase 8 warm-memory sequential ASCII parser benchmark");
    ascii_step.dependOn(&ascii_run.step);

    const ascii_numbers_mod = b.createModule(.{
        .target = target, .optimize = optimize,
        .root_source_file = b.path("benchmarks/ascii_numbers.zig"),
    });
    ascii_numbers_mod.addImport("zply_internals", internals_mod);
    const numbers_exe = b.addExecutable(.{ .name = "ascii_number_bench", .root_module = ascii_numbers_mod });
    const numbers_run = b.addRunArtifact(numbers_exe);
    const numbers_step = b.step("bench-ascii-numbers", "Benchmark ASCII tokenization and numeric conversion");
    numbers_step.dependOn(&numbers_run.step);
}
