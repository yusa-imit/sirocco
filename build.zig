const std = @import("std");

/// Build graph for sirocco — The wind that drives the fleet — async I/O runtime and network stack for Zig
///
/// Steps:
///   zig build            — build library + CLI
///   zig build test       — run all unit tests
///   zig build bench      — run benchmarks (ReleaseFast recommended)
///   zig build docs       — generate API docs into zig-out/docs
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module — consumers `@import("sirocco")`
    const mod = b.addModule("sirocco", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // CLI executable (diagnostics, version, small utilities)
    const exe = b.addExecutable(.{
        .name = "sirocco",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sirocco", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Tests
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Tidy — Tiger Style mechanical checks (tools/tidy.zig), run over src/bench/tests.
    const tidy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tidy_tests = b.addRunArtifact(tidy_tests);
    const tidy_exe = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(tidy_exe);
    const run_tidy_exe = b.addRunArtifact(tidy_exe);
    run_tidy_exe.addArgs(&.{ "src", "bench", "tests" });
    run_tidy_exe.step.dependOn(&run_tidy_tests.step);
    const tidy_step = b.step("tidy", "Run Tiger Style mechanical checks");
    tidy_step.dependOn(&run_tidy_exe.step);
    test_step.dependOn(&run_tidy_exe.step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "sirocco-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "sirocco", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Docs
    const docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&docs.step);
}
