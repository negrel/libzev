const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm = b.option(bool, "llvm", "Use LLVM backend") orelse false;

    const mod = b.addModule("zev", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests_mod = b.addModule("tests", .{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("zev", mod);

    const tests = b.addTest(.{
        .root_module = tests_mod,
        .use_llvm = llvm,
    });

    const run_mod_tests = b.addRunArtifact(tests);
    const install_mod_tests = b.addInstallArtifact(tests, .{});

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&install_mod_tests.step);
}
