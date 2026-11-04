const std = @import("std");
const llm = @import("client.zig");
const decisions = @import("decisions.zig");
const http = @import("transport.zig");
const types = @import("core/types.zig");

const response_start = "{\"model\":\"resolved-decision\",\"answers\":";
const response_end = ",\"usage\":{\"input_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":0,\"cache_write_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":12}}";
const boolean_response = response_start ++ "[{\"type\":\"predicate\",\"name\":\"decision\",\"probability\":0.9}]" ++ response_end;
const Team = enum { billing, technical, other };
const Triage = struct { team: Team, urgent: bool, severity: f64 };
const triage_response = response_start ++
    \\[{"type":"choice","name":"team","choice":"billing","probabilities":[{"value":"billing","probability":0.95},{"value":"technical","probability":0.03},{"value":"other","probability":0.02}],"confidence":0.925},{"type":"predicate","name":"urgent","probability":0.9},{"type":"score","name":"severity","score":1.1,"probabilities":[{"value":0,"label":"Minor","probability":0.1},{"value":1,"label":"Moderate","probability":0.7},{"value":2,"label":"Critical","probability":0.2}],"confidence":0.55}]
++ response_end;

const Script = struct {
    body: []const u8 = boolean_response,
    status: std.http.Status = .ok,
    calls: usize = 0,
    question_count: usize = 1,
    expected_query: ?[]const u8 = null,
    expect_extras: bool = false,
    send_error: ?anyerror = null,

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.send_error) |err| return err;
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        const query = std.mem.indexOfScalar(u8, request.url, '?') orelse request.url.len;
        try std.testing.expectEqualStrings("https://example.test/v1/decisions", request.url[0..query]);
        if (self.expected_query) |expected| try std.testing.expectEqualStrings(expected, request.url[query..]);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body.?, .{ .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings("decision-model", root.get("model").?.string);
        try std.testing.expectEqualStrings("The checkout button fails in Safari.", root.get("input").?.string);
        const questions = root.get("questions").?.array.items;
        try std.testing.expectEqual(self.question_count, questions.len);
        try std.testing.expect(root.get("text") == null);
        try std.testing.expect(root.get("response_format") == null);
        if (self.expect_extras) {
            const future = root.get("future").?.object;
            try std.testing.expect(future.get("default").?.bool);
            try std.testing.expect(future.get("request").?.bool);
            var custom: usize = 0;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "x-app")) {
                    custom += 1;
                    try std.testing.expectEqualStrings("request", header.value);
                }
            }
            try std.testing.expectEqual(@as(usize, 1), custom);
        }
        return .{ .allocator = allocator, .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }
};

fn config(allocator: std.mem.Allocator, script: *Script) llm.Config {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = .{ .openai = .{
            .api_key = "test-key",
            .base_url = "https://example.test/v1",
            .endpoint = .chat_completions,
        } },
        .model = "decision-model",
        .transport = .{ .ctx = script, .send_fn = Script.send },
    };
}

const input = "The checkout button fails in Safari.";
const boolean_question: decisions.Question(bool) = .{ .instructions = "Does the report describe broken behavior?" };
const triage_questions: @FieldType(decisions.ParseParams(Triage), "questions") = .{
    .team = .{ .instructions = "Which team owns this ticket?" },
    .urgent = .{ .instructions = "Does this need attention today?", .threshold = 0.8 },
    .severity = .{ .score = .{
        .instructions = "How severe is the issue?",
        .levels = &.{ .{ .label = "Minor" }, .{ .label = "Moderate" }, .{ .label = "Critical" } },
        .scale = .{ .minimum = 0, .maximum = 10 },
    } },
};

test "decision resource fields support native create and typed parse independently of the text endpoint" {
    var script: Script = .{};
    var client = try llm.Client.init(config(std.testing.allocator, &script));
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const questions = try decisions.buildQuestions(bool, arena.allocator(), boolean_question);
    var raw = try client.decisions.create(.{ .input = input, .questions = questions });
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw.value.answers.len);
    var parsed = try client.decisions.parse(bool, .{ .input = input, .questions = boolean_question });
    defer parsed.deinit();
    try std.testing.expect(parsed.value);
    try std.testing.expectEqual(@as(f64, 0.9), parsed.details.probability);
    try std.testing.expectEqual(@as(u64, 12), parsed.usage.input_tokens);
    try std.testing.expectEqualStrings("resolved-decision", parsed.model);
    try std.testing.expectEqual(@as(usize, 2), script.calls);
}

test "decision resource and returned distributions survive client moves and cleanup" {
    var script: Script = .{ .body = triage_response, .question_count = 3 };
    var parsed = blk: {
        var original = try llm.Client.init(config(std.testing.allocator, &script));
        const questions = decisions.Questions(Triage).init(&original, triage_questions);
        var moved = original;
        original = undefined;
        defer moved.deinit();
        break :blk try questions.parseDetailed(.{ .input = input });
    };
    defer parsed.deinit();
    try std.testing.expectEqual(Team.billing, parsed.value.team);
    try std.testing.expect(parsed.value.urgent);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), parsed.value.severity, 0.000001);
    try std.testing.expectEqual(@as(f64, 0.95), parsed.details.team.probabilities.get(.billing));
    try std.testing.expectEqualStrings(triage_response, parsed.raw_response);
    try std.testing.expectEqualStrings("resolved-decision", parsed.response.model);
}

test "decision requests merge copied client defaults and request extras" {
    var script: Script = .{ .expect_extras = true, .expected_query = "?client=a%20b&route=new" };
    var client = blk: {
        const body = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"future\":{\"default\":true}}", .{});
        defer body.deinit();
        var cfg = config(std.testing.allocator, &script);
        cfg.extra_body = body.value;
        cfg.extra_query = &.{ .{ .name = "route", .value = "old" }, .{ .name = "client", .value = "a b" } };
        cfg.headers = &.{.{ .name = "X-App", .value = "default" }};
        break :blk try llm.Client.init(cfg);
    };
    defer client.deinit();
    const extra = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"future\":{\"request\":true}}", .{});
    defer extra.deinit();
    var parsed = try client.decisions.parse(bool, .{
        .input = input,
        .questions = boolean_question,
        .extra_body = extra.value,
        .extra_headers = &.{.{ .name = "x-app", .value = "request" }},
        .extra_query = &.{.{ .name = "route", .value = "new" }},
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value);
    try std.testing.expect(try client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
        .model = "decision-model",
        .extra_body = extra.value,
        .extra_headers = &.{.{ .name = "x-app", .value = "request" }},
        .extra_query = &.{.{ .name = "route", .value = "new" }},
    }));
    const questions = decisions.Questions(bool).init(&client, boolean_question);
    try std.testing.expect(try questions.parse(.{
        .input = input,
        .model = "decision-model",
        .extra_body = extra.value,
        .extra_headers = &.{.{ .name = "x-app", .value = "request" }},
        .extra_query = &.{.{ .name = "route", .value = "new" }},
    }));
    try std.testing.expectEqual(@as(usize, 3), script.calls);
}

test "invalid decision questions and unsupported providers fail before HTTP" {
    var script: Script = .{};
    var client = try llm.Client.init(config(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.EmptyInstructions, client.decisions.parse(bool, .{ .input = input, .questions = .{ .instructions = "" } }));
    try std.testing.expectError(error.InvalidThreshold, client.decisions.parse(bool, .{ .input = input, .questions = .{ .instructions = "Question", .threshold = std.math.nan(f64) } }));
    var cfg = config(std.testing.allocator, &script);
    cfg.provider = .{ .anthropic = .{ .api_key = "test-key" } };
    var anthropic = try llm.Client.init(cfg);
    defer anthropic.deinit();
    try std.testing.expectError(error.UnsupportedDecisionProvider, anthropic.decisions.parse(bool, .{ .input = input, .questions = boolean_question }));
    try std.testing.expectEqual(@as(usize, 0), script.calls);
}

const HookLog = struct {
    events: [8]types.HookEvent = undefined,
    len: usize = 0,

    fn event(ctx: ?*anyopaque, kind: types.HookEvent, _: types.HookInfo) void {
        const self: *HookLog = @ptrCast(@alignCast(ctx.?));
        self.events[self.len] = kind;
        self.len += 1;
    }
};

test "decision refusals preserve diagnostics and do not retry or report completion" {
    var script: Script = .{ .status = .created, .body = response_start ++ "[{\"type\":\"refusal\",\"name\":\"decision\"}]" ++ response_end };
    var log: HookLog = .{};
    var cfg = config(std.testing.allocator, &script);
    cfg.hooks = .{ .ctx = &log, .on_event = HookLog.event };
    var client = try llm.Client.init(cfg);
    defer client.deinit();
    try std.testing.expectError(error.Refusal, client.decisions.parse(bool, .{ .input = input, .questions = boolean_question }));
    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expectEqual(std.http.Status.created, client.diagnostic().status.?);
    try std.testing.expectEqualStrings(script.body, client.diagnostic().body.?);
    try std.testing.expectEqualSlices(types.HookEvent, &.{ .request_start, .response_received, .parse_error }, log.events[0..log.len]);
}

test "condition uses the default threshold and includes equality" {
    var script: Script = .{
        .body = response_start ++ "[{\"type\":\"predicate\",\"name\":\"decision\",\"probability\":0.5}]" ++ response_end,
    };
    var client = try llm.Client.init(config(std.testing.allocator, &script));
    defer client.deinit();
    const params: decisions.ConditionParams = .{ .input = input, .instructions = boolean_question.instructions };
    try std.testing.expect(try client.decisions.condition(params));
    try std.testing.expect(!try client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
        .threshold = 0.5001,
    }));
    try std.testing.expect(try client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
        .threshold = 0.4999,
    }));
}

test "condition rejects invalid questions without sending a request" {
    var script: Script = .{};
    var client = try llm.Client.init(config(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.EmptyInstructions, client.decisions.condition(.{ .input = input, .instructions = "" }));
    try std.testing.expectError(error.InvalidThreshold, client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
        .threshold = std.math.nan(f64),
    }));
    try std.testing.expectEqual(@as(usize, 0), script.calls);
}

test "condition propagates refusals malformed answers and HTTP failures" {
    const cases = [_]struct { body: []const u8, status: std.http.Status, expected: anyerror }{
        .{ .body = response_start ++ "[{\"type\":\"refusal\",\"name\":\"decision\"}]" ++ response_end, .status = .ok, .expected = error.Refusal },
        .{ .body = response_start ++ "[{\"type\":\"predicate\",\"name\":\"wrong\",\"probability\":0.5}]" ++ response_end, .status = .ok, .expected = error.InvalidDecisionResponse },
        .{ .body = "{\"error\":{\"message\":\"rate limited\"}}", .status = .too_many_requests, .expected = error.ProviderHttpError },
    };
    for (cases) |case| {
        var script: Script = .{ .body = case.body, .status = case.status };
        var client = try llm.Client.init(config(std.testing.allocator, &script));
        defer client.deinit();
        try std.testing.expectError(case.expected, client.decisions.condition(.{
            .input = input,
            .instructions = boolean_question.instructions,
        }));
        try std.testing.expectEqual(@as(usize, 1), script.calls);
    }
}

test "question sets return independent values without response cleanup at the call site" {
    var script: Script = .{ .body = triage_response, .question_count = 3 };
    const value = blk: {
        var client = try llm.Client.init(config(std.testing.allocator, &script));
        defer client.deinit();
        const questions = decisions.Questions(Triage).init(&client, triage_questions);
        break :blk try questions.parse(.{ .input = input });
    };
    try std.testing.expectEqual(Team.billing, value.team);
    try std.testing.expect(value.urgent);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), value.severity, 0.000001);
}

test "question sets and conditions forward model overrides" {
    var script: Script = .{};
    var cfg = config(std.testing.allocator, &script);
    cfg.model = "other-model";
    var client = try llm.Client.init(cfg);
    defer client.deinit();
    const questions = decisions.Questions(bool).init(&client, boolean_question);
    try std.testing.expectEqual(@as(usize, 0), script.calls);
    try std.testing.expect(try questions.parse(.{ .input = input, .model = "decision-model" }));
    try std.testing.expect(try client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
        .model = "decision-model",
    }));
    try std.testing.expectEqual(@as(usize, 2), script.calls);
}

test "value helpers propagate transport errors without converting them to false" {
    var script: Script = .{ .send_error = error.ConnectionResetByPeer };
    var client = try llm.Client.init(config(std.testing.allocator, &script));
    defer client.deinit();
    const questions = decisions.Questions(bool).init(&client, boolean_question);
    try std.testing.expectError(error.ConnectionResetByPeer, questions.parse(.{ .input = input }));
    try std.testing.expectError(error.ConnectionResetByPeer, client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
    }));
    try std.testing.expectEqual(@as(usize, 2), script.calls);
}

fn exerciseQuestionSet(allocator: std.mem.Allocator) !void {
    var script: Script = .{};
    var client = try llm.Client.init(config(allocator, &script));
    defer client.deinit();
    const questions = decisions.Questions(bool).init(&client, boolean_question);
    try std.testing.expect(try questions.parse(.{ .input = input }));
}

test "question sets clean up response memory on every allocation failure" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), exerciseQuestionSet, .{});
}

fn exerciseCondition(allocator: std.mem.Allocator) !void {
    var script: Script = .{};
    var client = try llm.Client.init(config(allocator, &script));
    defer client.deinit();
    try std.testing.expect(try client.decisions.condition(.{
        .input = input,
        .instructions = boolean_question.instructions,
    }));
}

test "condition cleans up response memory on every allocation failure" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), exerciseCondition, .{});
}

fn exercise(allocator: std.mem.Allocator) !void {
    var script: Script = .{};
    var client = try llm.Client.init(config(allocator, &script));
    defer client.deinit();
    var parsed = try client.decisions.parse(bool, .{ .input = input, .questions = boolean_question });
    defer parsed.deinit();
    try std.testing.expect(parsed.value);
}

test "decision client and owned result release every partial allocation" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), exercise, .{});
}
