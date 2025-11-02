const std = @import("std");
const Step = std.Build.Step;

pub fn build(b: *std.Build) !void {
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

    const examples_step = b.step("examples", "Build examples");
    for (try buildExamples(b, target, optimize, llvm)) |compile| {
        const install_example = b.addInstallArtifact(compile, .{});
        examples_step.dependOn(&install_example.step);
    }
}

fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    llvm: bool,
) ![]const *Step.Compile {
    const alloc = b.allocator;
    var steps: std.ArrayList(*Step.Compile) = .empty;
    defer steps.deinit(alloc);

    var dir = try std.fs.cwd().openDir(try b.build_root.join(
        b.allocator,
        &.{"examples"},
    ), .{ .iterate = true });
    defer dir.close();

    // Go through and add each as a step
    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(
            u8,
            entry.name,
            '.',
        ) orelse continue;
        if (index == 0) continue;

        // Name of the app and full path to the entrypoint.
        const name = entry.name[0..index];

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt(
                    "examples/{s}",
                    .{entry.name},
                )),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = llvm,
        });
        exe.root_module.addImport("zev", b.modules.get("zev").?);

        // Store the mapping
        try steps.append(alloc, exe);
    }

    return try steps.toOwnedSlice(alloc);
}
