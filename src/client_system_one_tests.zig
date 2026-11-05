const std = @import("std");
const llm = @import("client.zig");
const decisions = @import("decisions.zig");
const http = @import("transport.zig");

const bool_response =
    \\{"model":"jev-test","answers":{"decision":{"type":"noul","noul":0.9}},"usage":{"input_tokens":12,"output_tokens":0}}
;
const triage_response =
    \\{"model":"jev-test","answers":{"severity":{"type":"score","score":1.1,"confidence":0.55,"probabilities":{"2":0.2,"0":0.1,"1":0.7},"legend":{"2":{"label":"high"},"1":{"label":"medium","description":"Partial outage"},"0":{"label":"low"}}},"urgent":{"type":"noul","noul":0.9},"team":{"type":"choice","choice":"billing","confidence":0,"probabilities":{"other":0.33,"billing":0.33,"technical":0.33}}},"usage":{"input_tokens":12,"output_tokens":0},"future":true}
;
const Team = enum { billing, technical, other };
const Triage = struct { team: Team, urgent: bool, severity: f64 };
const questions: @FieldType(decisions.ParseParams(Triage), "questions") = .{
    .team = .{ .instructions = "Which team?" },
    .urgent = .{ .instructions = "Is it urgent?", .threshold = 0.8 },
    .severity = .{ .score = .{
        .instructions = "How severe?",
        .levels = &.{ .{ .label = "low" }, .{ .label = "medium", .description = "Partial outage" }, .{ .label = "high" } },
        .scale = .{ .minimum = 0, .maximum = 10 },
    } },
};

const Script = struct {
    body: []const u8 = bool_response,
    status: std.http.Status = .ok,
    url: []const u8 = "https://api.typesafe.ai/v1/systemone",
    model: []const u8 = "jev-latest",
    triage: bool = false,
    extras: bool = false,
    calls: usize = 0,

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        try std.testing.expectEqualStrings(self.url, request.url);
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        var auth_count: usize = 0;
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                auth_count += 1;
                try std.testing.expectEqualStrings("Bearer test-key", header.value);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), auth_count);
        const payload = try std.json.parseFromSlice(std.json.Value, allocator, request.body.?, .{ .duplicate_field_behavior = .@"error" });
        defer payload.deinit();
        const root = payload.value.object;
        try std.testing.expectEqualStrings(self.model, root.get("model").?.string);
        try std.testing.expectEqualStrings("A ticket", root.get("state").?.string);
        try std.testing.expect(!root.contains("input"));
        const qs = root.get("questions").?.object;
        if (self.triage) {
            try std.testing.expectEqual(@as(usize, 3), qs.count());
            const criteria = qs.get("team").?.object.get("criteria").?.object;
            try std.testing.expectEqualStrings("billing", criteria.get("billing").?.string);
            const levels = qs.get("severity").?.object.get("criteria").?.array.items;
            try std.testing.expectEqualStrings("medium", levels[1].object.get("label").?.string);
            try std.testing.expectEqualStrings("Partial outage", levels[1].object.get("description").?.string);
        } else {
            try std.testing.expectEqual(@as(usize, 1), qs.count());
            try std.testing.expectEqualStrings("noul", qs.get("decision").?.object.get("type").?.string);
        }
        if (self.extras) {
            const options = root.get("provider").?.object;
            try std.testing.expect(options.get("default").?.bool);
            try std.testing.expect(options.get("request").?.bool);
            var header_count: usize = 0;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "x-app")) {
                    header_count += 1;
                    try std.testing.expectEqualStrings("request", header.value);
                }
            }
            try std.testing.expectEqual(@as(usize, 1), header_count);
        }
        return .{ .allocator = allocator, .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }
};

fn config(allocator: std.mem.Allocator, script: *Script) llm.Config {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = .{ .typesafe = .{ .api_key = "test-key" } },
        .transport = .{ .ctx = script, .send_fn = Script.send },
    };
}

test "one System One adapter uses direct TypeSafe OpenRouter and Vercel configuration" {
    const services = .{
        .{ "https://api.typesafe.ai/v1", "jev-latest" },
        .{ "https://openrouter.ai/api/v1", "typesafe/jev-1.13" },
        .{ "https://ai-gateway.vercel.sh/typesafe/v1", "typesafe-ai/jev" },
    };
    inline for (services) |service| {
        var script: Script = .{ .url = service[0] ++ "/systemone", .model = service[1] };
        var cfg = config(std.testing.allocator, &script);
        cfg.provider.typesafe.base_url = service[0];
        cfg.model = service[1];
        var client = try llm.Client.init(cfg);
        defer client.deinit();
        try std.testing.expect(try client.decisions.condition(.{ .input = "A ticket", .instructions = "Is it urgent?", .threshold = 0.8 }));
        try std.testing.expectEqual(@as(usize, 1), script.calls);
    }
}

fn triageExercise(allocator: std.mem.Allocator) !decisions.Parsed(Triage) {
    var script: Script = .{ .body = triage_response, .triage = true };
    var original = try llm.Client.init(config(allocator, &script));
    const bound = decisions.Questions(Triage).init(&original, questions);
    var client = original;
    original = undefined;
    defer client.deinit();
    return bound.parseDetailed(.{ .input = "A ticket" });
}

test "System One matches answer IDs preserves rounding and owns results across client cleanup" {
    var result = try triageExercise(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqual(Team.billing, result.value.team);
    try std.testing.expect(result.value.urgent);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), result.value.severity, 1e-10);
    try std.testing.expectEqual(@as(f64, 0.33), result.details.team.probabilities.get(.other));
    try std.testing.expectEqual(@as(u64, 12), result.usage.total_tokens);
    try std.testing.expectEqualStrings(triage_response, result.raw_response);
    for (result.details.severity.score.probabilities) |entry| {
        if (entry.value == 1) try std.testing.expectEqualStrings("medium", entry.label);
    }
    try std.testing.expectEqual(@as(?u8, 2), result.rounding);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var result = try triageExercise(allocator);
    defer result.deinit();
}

test "System One client request decode and result allocation failures clean up" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), allocationExercise, .{});
}

test "System One copies configuration and merges extras with protected state" {
    var script: Script = .{ .extras = true, .url = "https://api.typesafe.ai/v1/systemone?source=client&route=request" };
    var client = blk: {
        var cfg = config(std.testing.allocator, &script);
        const extra = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"provider\":{\"default\":true}}", .{});
        defer extra.deinit();
        cfg.extra_body = extra.value;
        cfg.extra_query = &.{ .{ .name = "source", .value = "client" }, .{ .name = "route", .value = "old" } };
        cfg.headers = &.{.{ .name = "X-App", .value = "client" }};
        break :blk try llm.Client.init(cfg);
    };
    defer client.deinit();
    const extra = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"provider\":{\"request\":true}}", .{});
    defer extra.deinit();
    try std.testing.expect(try client.decisions.condition(.{
        .input = "A ticket",
        .instructions = "Is it urgent?",
        .extra_body = extra.value,
        .extra_query = &.{.{ .name = "route", .value = "request" }},
        .extra_headers = &.{.{ .name = "x-app", .value = "request" }},
    }));
    inline for (.{ "{\"state\":\"other\"}", "{\"questions\":{}}", "{\"model\":\"other\"}" }) |json| {
        const reserved = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer reserved.deinit();
        try std.testing.expectError(error.ReservedBodyField, client.decisions.condition(.{ .input = "A ticket", .instructions = "Question", .extra_body = reserved.value }));
    }
    try std.testing.expectEqual(@as(usize, 1), script.calls);
}

test "System One failures retain diagnostics never become false and do not retry" {
    var script: Script = .{ .status = .unauthorized, .body = "{\"detail\":\"Denied\"}" };
    var client = try llm.Client.init(config(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.ProviderHttpError, client.decisions.condition(.{ .input = "A ticket", .instructions = "Question" }));
    try std.testing.expectEqualStrings("typesafe", client.diagnostic().provider);
    try std.testing.expectEqual(std.http.Status.unauthorized, client.diagnostic().status.?);
    try std.testing.expectEqualStrings(script.body, client.diagnostic().body.?);
    script.status = .ok;
    script.body = "{\"model\":\"jev-test\",\"answers\":{\"decision\":{\"type\":\"refusal\"}},\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}";
    try std.testing.expectError(error.Refusal, client.decisions.condition(.{ .input = "A ticket", .instructions = "Question" }));
    try std.testing.expectEqual(std.http.Status.ok, client.diagnostic().status.?);
    try std.testing.expectEqual(@as(usize, 2), script.calls);
    script.body = "{\"error\":{\"message\":\"Rejected\"}}";
    try std.testing.expectError(error.ProviderHttpError, client.decisions.condition(.{ .input = "A ticket", .instructions = "Question" }));
    try std.testing.expectError(error.UnsupportedTextProvider, client.responses.create(.{ .input = "Text" }));
    try std.testing.expectError(error.UnsupportedTextProvider, client.messages.parse(struct {
        value: bool,
        pub const jsonschema = .{ .name = "TestValue" };
    }, .{ .messages = &.{.{ .role = .user, .content = "Extract" }} }));
    try std.testing.expect(client.diagnostic().body == null);
    try std.testing.expectEqual(@as(usize, 3), script.calls);
}
