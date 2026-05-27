const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Main executable ──────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "ctm",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the token monitor");
    run_step.dependOn(&run_cmd.step);

    // ── Test suite ───────────────────────────────────────────────────
    // We compile each test file as its own test binary, but expose the
    // source modules under stable import names so tests can pull them in
    // via @import("config"), @import("usage_reader"), etc.

    const test_step = b.step("test", "Run all unit tests");

    const test_files = [_][]const u8{
        "tests/test_config.zig",
        "tests/test_usage_reader.zig",
        "tests/test_session_tracker.zig",
    };

    // Coverage support: `zig build test -Dcoverage=true` wraps each test
    // binary in `kcov` so you get HTML reports under zig-out/coverage/.
    const coverage = b.option(bool, "coverage", "Generate coverage report with kcov") orelse false;
    const cov_out = b.pathJoin(&.{ b.install_path, "coverage" });

    for (test_files) |path| {
        const t = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        // Re-export source modules so tests can @import them by name.
        t.root_module.addAnonymousImport("config", .{
            .root_source_file = b.path("src/config.zig"),
        });
        t.root_module.addAnonymousImport("usage_reader", .{
            .root_source_file = b.path("src/usage_reader.zig"),
        });
        t.root_module.addAnonymousImport("session_tracker", .{
            .root_source_file = b.path("src/session_tracker.zig"),
        });

        if (coverage) {
            const run = b.addSystemCommand(&.{
                "kcov",
                "--clean",
                "--include-pattern=src/",
                cov_out,
            });
            run.addArtifactArg(t);
            test_step.dependOn(&run.step);
        } else {
            const run = b.addRunArtifact(t);
            test_step.dependOn(&run.step);
        }
    }

    // Also run the inline tests inside src/usage_reader.zig
    const inline_tests = b.addTest(.{
        .root_source_file = b.path("src/usage_reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_inline = b.addRunArtifact(inline_tests);
    test_step.dependOn(&run_inline.step);
}
