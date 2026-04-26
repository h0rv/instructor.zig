const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jsonschema_dep = b.dependency("jsonschema", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("instructor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonschema", .module = jsonschema_dep.module("jsonschema") },
        },
    });

    const openrouter_example = addExample(b, mod, target, optimize, "openrouter-example", "examples/openrouter.zig", "run-openrouter", "Run OpenRouter example");
    const tool_planner_example = addExample(b, mod, target, optimize, "tool-planner-example", "examples/tool_planner.zig", "run-tool-planner", "Run tool planner example");
    const exact_citations_example = addExample(b, mod, target, optimize, "exact-citations-example", "examples/exact_citations.zig", "run-exact-citations", "Run exact citations example");
    const action_items_example = addExample(b, mod, target, optimize, "action-items-example", "examples/action_items.zig", "run-action-items", "Run action items example");
    const agent_example = addExample(b, mod, target, optimize, "agent-example", "examples/agent.zig", "run-agent", "Run agent example");

    const examples_step = b.step("examples", "Build examples");
    examples_step.dependOn(openrouter_example);
    examples_step.dependOn(tool_planner_example);
    examples_step.dependOn(exact_citations_example);
    examples_step.dependOn(action_items_example);
    examples_step.dependOn(agent_example);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(examples_step);
}

fn addExample(
    b: *std.Build,
    instructor_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    path: []const u8,
    step_name: []const u8,
    step_description: []const u8,
) *std.Build.Step {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "instructor", .module = instructor_mod },
            },
        }),
    });

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step(step_name, step_description);
    step.dependOn(&run.step);
    return &exe.step;
}
