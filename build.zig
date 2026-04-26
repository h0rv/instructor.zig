const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jsonschema_dep = b.dependency("jsonschema", .{
        .target = target,
        .optimize = optimize,
    });
    const openai_dep = b.dependency("openai", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("instructor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonschema", .module = jsonschema_dep.module("jsonschema") },
            .{ .name = "openai", .module = openai_dep.module("openai") },
        },
    });

    const docs_lib = b.addLibrary(.{
        .name = "instructor",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API docs");
    docs_step.dependOn(&install_docs.step);

    const serve_docs = b.addExecutable(.{
        .name = "serve-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve_docs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_serve_docs = b.addRunArtifact(serve_docs);
    run_serve_docs.addArg("zig-out/docs");
    run_serve_docs.addArg("8000");
    run_serve_docs.step.dependOn(docs_step);
    const serve_docs_step = b.step("run-serve-docs", "Generate and serve API docs");
    serve_docs_step.dependOn(&run_serve_docs.step);

    const openrouter_example = addExample(b, mod, target, optimize, "openrouter-example", "examples/openrouter.zig", "run-openrouter", "Run OpenRouter example");
    const tool_planner_example = addExample(b, mod, target, optimize, "tool-planner-example", "examples/tool_planner.zig", "run-tool-planner", "Run tool planner example");
    const exact_citations_example = addExample(b, mod, target, optimize, "exact-citations-example", "examples/exact_citations.zig", "run-exact-citations", "Run exact citations example");
    const action_items_example = addExample(b, mod, target, optimize, "action-items-example", "examples/action_items.zig", "run-action-items", "Run action items example");
    const agent_example = addExample(b, mod, target, optimize, "agent-example", "examples/agent.zig", "run-agent", "Run agent example");
    const native_tool_call_example = addExample(b, mod, target, optimize, "native-tool-call-example", "examples/native_tool_call.zig", "run-native-tool-call", "Run native tool-call example");
    const multimodal_inspection_example = addExample(b, mod, target, optimize, "multimodal-inspection-example", "examples/multimodal_inspection.zig", "run-multimodal-inspection", "Run multimodal inspection example");
    const support_router_example = addExample(b, mod, target, optimize, "support-router-example", "examples/support_router.zig", "run-support-router", "Run support router example");
    const invoice_extraction_example = addExample(b, mod, target, optimize, "invoice-extraction-example", "examples/invoice_extraction.zig", "run-invoice-extraction", "Run invoice extraction example");
    const llm_judge_example = addExample(b, mod, target, optimize, "llm-judge-example", "examples/llm_judge.zig", "run-llm-judge", "Run LLM judge example");
    const pii_redaction_example = addExample(b, mod, target, optimize, "pii-redaction-example", "examples/pii_redaction.zig", "run-pii-redaction", "Run PII redaction example");
    const query_understanding_example = addExample(b, mod, target, optimize, "query-understanding-example", "examples/query_understanding.zig", "run-query-understanding", "Run query understanding example");
    const batch_extract_example = addExample(b, mod, target, optimize, "batch-extract-example", "examples/batch_extract.zig", "run-batch-extract", "Run batch extraction example");
    const responses_tool_call_example = addExample(b, mod, target, optimize, "responses-tool-call-example", "examples/responses_tool_call.zig", "run-responses-tool-call", "Run Responses tool-call example");
    const classify_union_example = addExample(b, mod, target, optimize, "classify-union-example", "examples/classify_union.zig", "run-classify-union", "Run tagged-union classifier example");

    const examples_step = b.step("examples", "Build examples");
    examples_step.dependOn(openrouter_example);
    examples_step.dependOn(tool_planner_example);
    examples_step.dependOn(exact_citations_example);
    examples_step.dependOn(action_items_example);
    examples_step.dependOn(agent_example);
    examples_step.dependOn(native_tool_call_example);
    examples_step.dependOn(multimodal_inspection_example);
    examples_step.dependOn(support_router_example);
    examples_step.dependOn(invoice_extraction_example);
    examples_step.dependOn(llm_judge_example);
    examples_step.dependOn(pii_redaction_example);
    examples_step.dependOn(query_understanding_example);
    examples_step.dependOn(batch_extract_example);
    examples_step.dependOn(responses_tool_call_example);
    examples_step.dependOn(classify_union_example);

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
