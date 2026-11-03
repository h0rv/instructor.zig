const std = @import("std");
const llm = @import("client.zig");
const http = @import("transport.zig");

const Person = struct {
    name: []const u8,
    age: u8,
};

const Case = enum { responses, chat, anthropic };
const cases = [_]Case{ .responses, .chat, .anthropic };

fn bodyFor(comptime case: Case, comptime escaped_text: []const u8) []const u8 {
    return switch (case) {
        .responses => "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"" ++ escaped_text ++ "\"}]}],\"usage\":{\"input_tokens\":2,\"output_tokens\":3,\"total_tokens\":5}}",
        .chat => "{\"choices\":[{\"message\":{\"content\":\"" ++ escaped_text ++ "\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}",
        .anthropic => "{\"content\":[{\"type\":\"text\",\"text\":\"" ++ escaped_text ++ "\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}",
    };
}

const person_json = "{\\\"name\\\":\\\"Robby\\\",\\\"age\\\":24}";
const Reply = struct {
    body: []const u8,
    structured: bool = false,
    status: std.http.Status = .ok,
    message_count: ?usize = null,
};

const Script = struct {
    case: Case,
    replies: []const Reply,
    calls: usize = 0,
    expected_model: []const u8 = "test-model",
    no_auth: bool = false,
    auth_override: ?[]const u8 = null,
    expected_custom_header: ?[]const u8 = null,

    fn transport(self: *Script) http.Transport {
        return .{ .ctx = self, .send_fn = send };
    }

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        if (self.calls >= self.replies.len) return error.UnexpectedRequest;
        const reply = self.replies[self.calls];
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        try std.testing.expect(std.mem.endsWith(u8, request.url, switch (self.case) {
            .responses => "/responses",
            .chat => "/chat/completions",
            .anthropic => "/v1/messages",
        }));
        var auth_count: usize = 0;
        var found_custom = false;
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, if (self.case == .anthropic) "x-api-key" else "Authorization")) {
                try std.testing.expect(!self.no_auth);
                try std.testing.expectEqualStrings(self.auth_override orelse (if (self.case == .anthropic) "secret" else "Bearer secret"), header.value);
                auth_count += 1;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "x-app")) {
                try std.testing.expectEqualStrings(self.expected_custom_header.?, header.value);
                found_custom = true;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                try std.testing.expectEqualStrings("application/json", header.value);
            }
            if (self.case == .anthropic) try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "Authorization"));
        }
        try std.testing.expectEqual(@as(usize, if (self.no_auth) 0 else 1), auth_count);
        try std.testing.expectEqual(self.expected_custom_header != null, found_custom);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body.?, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings(self.expected_model, root.get("model").?.string);
        const format = switch (self.case) {
            .responses => if (root.get("text")) |text| text.object.get("format") else null,
            .chat => root.get("response_format"),
            .anthropic => if (root.get("output_config")) |config| config.object.get("format") else null,
        };
        try std.testing.expectEqual(reply.structured, format != null);
        try std.testing.expect(root.get("tools") == null);
        if (reply.message_count) |count| {
            const messages = root.get(if (self.case == .responses) "input" else "messages").?.array.items;
            try std.testing.expectEqual(count, messages.len);
        }
        const body = try allocator.dupe(u8, reply.body);
        self.calls += 1;
        return .{ .allocator = allocator, .status = reply.status, .body = body };
    }
};

fn configFor(allocator: std.mem.Allocator, script: *Script) llm.Config {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = switch (script.case) {
            .responses, .chat => .{ .openai = .{
                .api_key = "secret",
                .endpoint = if (script.case == .chat) .chat_completions else .responses,
            } },
            .anthropic => .{ .anthropic = .{ .api_key = "secret" } },
        },
        .model = "test-model",
        .transport = script.transport(),
    };
}

test "one request API completes and extracts through all built-in adapters" {
    inline for (cases) |case| {
        var script: Script = .{ .case = case, .replies = &.{
            .{ .body = bodyFor(case, "Hello"), .message_count = 1 },
            .{ .body = bodyFor(case, person_json), .structured = true, .message_count = 1 },
        } };
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        var reply = try client.text("Say hello.");
        defer reply.deinit();
        try std.testing.expectEqualStrings("Hello", reply.text);
        try std.testing.expectEqual(@as(u64, 5), reply.usage.total_tokens);

        var person = try client.extract(Person, .{ .prompt = "Robby is 24." });
        defer person.deinit();
        try std.testing.expectEqualStrings("Robby", person.value.name);
        try std.testing.expectEqual(@as(u8, 24), person.value.age);
        try std.testing.expectEqual(@as(usize, 2), script.calls);
    }
}

test "validation retries use the existing engine and keep cumulative usage" {
    inline for (cases) |case| {
        var script: Script = .{ .case = case, .replies = &.{
            .{ .body = bodyFor(case, "{\\\"name\\\":\\\"Robby\\\",\\\"age\\\":300}"), .structured = true, .message_count = 1 },
            .{ .body = bodyFor(case, person_json), .structured = true, .message_count = 3 },
        } };
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        var person = try client.extract(Person, .{ .prompt = "Robby is 24." });
        defer person.deinit();
        try std.testing.expectEqual(@as(u8, 24), person.value.age);
        try std.testing.expectEqual(@as(u64, 10), person.usage.total_tokens);
        try std.testing.expectEqual(@as(usize, 2), script.calls);
    }
}

fn extractAfterClientDies(allocator: std.mem.Allocator) !llm.Owned(Person) {
    var script: Script = .{ .case = .anthropic, .replies = &.{.{ .body = bodyFor(.anthropic, person_json), .structured = true }} };
    var client = try llm.Client.init(configFor(allocator, &script));
    defer client.deinit();
    return client.extract(Person, .{ .prompt = "Robby is 24." });
}

fn completeAfterClientDies(allocator: std.mem.Allocator) !llm.Response {
    var script: Script = .{ .case = .responses, .replies = &.{.{ .body = bodyFor(.responses, "Hello") }} };
    var client = try llm.Client.init(configFor(allocator, &script));
    defer client.deinit();
    return client.text("Say hello.");
}

test "owned results move and outlive clients including model and raw response strings" {
    var original = try extractAfterClientDies(std.testing.allocator);
    var moved = original;
    original = undefined;
    defer moved.deinit();
    try std.testing.expectEqualStrings("Robby", moved.value.name);
    try std.testing.expectEqualStrings("test-model", moved.model);
    try std.testing.expect(moved.raw_response.len > 0);
    const later = try moved.arena.allocator().dupe(u8, "still live");
    try std.testing.expectEqualStrings("still live", later);

    var response = try completeAfterClientDies(std.testing.allocator);
    defer response.deinit();
    try std.testing.expectEqualStrings("Hello", response.text);
    try std.testing.expectEqualStrings("test-model", response.model);
}

test "caller arena results retain copied text even with allocate if needed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var script: Script = .{ .case = .anthropic, .replies = &.{.{ .body = bodyFor(.anthropic, person_json), .structured = true }} };
    const saved = blk: {
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        break :blk try client.extractIntoWith(Person, arena.allocator(), .{ .prompt = "Robby is 24." }, .{
            .parse_options = .{ .allocate = .alloc_if_needed },
        });
    };
    try std.testing.expectEqualStrings("Robby", saved.name);
    // Independently exercise an owned result with the same parse policy.
    var owned_script: Script = .{ .case = .responses, .replies = &.{.{ .body = bodyFor(.responses, person_json), .structured = true }} };
    var client = try llm.Client.init(configFor(std.testing.allocator, &owned_script));
    defer client.deinit();
    var person = try client.extractWith(Person, .{ .prompt = "Robby is 24." }, .{ .parse_options = .{ .allocate = .alloc_if_needed } });
    defer person.deinit();
    try std.testing.expectEqualStrings("Robby", person.value.name);
}

test "configuration strings are copied and per-call model overrides are owned" {
    var key = "secret".*;
    var model = "test-model".*;
    var script: Script = .{ .case = .responses, .expected_model = "override-model", .replies = &.{.{ .body = bodyFor(.responses, "Hello") }} };
    var config = configFor(std.testing.allocator, &script);
    config.model = &model;
    config.provider.openai.api_key = &key;
    var client = try llm.Client.init(config);
    defer client.deinit();
    @memset(&key, 'x');
    @memset(&model, 'x');
    try std.testing.expectEqualStrings("test-model", client.model);
    var override = "override-model".*;
    var response = try client.complete(.{ .prompt = "Hello", .model = &override });
    defer response.deinit();
    @memset(&override, 'x');
    try std.testing.expectEqualStrings("override-model", response.model);
}

test "input validation and unsupported controls fail without invoking transport" {
    var script: Script = .{ .case = .anthropic, .replies = &.{} };
    var client = try llm.Client.init(configFor(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.MissingInput, client.complete(.{}));
    try std.testing.expectError(error.UnsupportedControl, client.complete(.{ .prompt = "Hello", .temperature = 0.5 }));
    try std.testing.expectError(error.InvalidMaxOutputTokens, client.complete(.{ .prompt = "Hello", .max_output_tokens = 0 }));
    try std.testing.expectError(error.MissingModel, client.complete(.{ .prompt = "Hello", .model = "" }));
    try std.testing.expectEqual(@as(usize, 0), script.calls);
}

test "prompt appends to history and failed requests retain diagnostics" {
    var script: Script = .{ .case = .chat, .replies = &.{.{ .body = "{\"error\":{\"message\":\"denied\"}}", .status = .forbidden, .message_count = 2 }} };
    var client = try llm.Client.init(configFor(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.ProviderHttpError, client.complete(.{
        .messages = &.{.{ .role = .assistant, .content = "Earlier reply" }},
        .prompt = "Continue",
    }));
    try std.testing.expectEqual(std.http.Status.forbidden, client.diagnostic().status.?);
    try std.testing.expect(client.diagnostic().body != null);
    try std.testing.expectError(error.MissingInput, client.complete(.{}));
    try std.testing.expect(client.diagnostic().status == null);
}

test "custom headers are copied and canonical authentication is not duplicated" {
    var header_value = "custom".*;
    var script: Script = .{ .case = .responses, .expected_custom_header = "custom", .replies = &.{.{ .body = bodyFor(.responses, "Hello") }} };
    var config = configFor(std.testing.allocator, &script);
    config.headers = &.{
        .{ .name = "X-App", .value = &header_value },
        .{ .name = "authorization", .value = "old" },
        .{ .name = "Authorization", .value = "also old" },
        .{ .name = "CONTENT-TYPE", .value = "text/plain" },
    };
    var client = try llm.Client.init(config);
    defer client.deinit();
    @memset(&header_value, 'x');
    var response = try client.text("Hello");
    defer response.deinit();
}

test "local compatible endpoints can omit authentication or supply an explicit header" {
    inline for ([_]bool{ false, true }) |custom_auth| {
        var script: Script = .{ .case = .chat, .no_auth = !custom_auth, .auth_override = if (custom_auth) "Bearer external" else null, .replies = &.{.{ .body = bodyFor(.chat, "Hello") }} };
        var config = configFor(std.testing.allocator, &script);
        config.provider.openai.api_key = "";
        if (custom_auth) config.headers = &.{.{ .name = "Authorization", .value = "Bearer external" }};
        var client = try llm.Client.init(config);
        defer client.deinit();
        var response = try client.text("Hello");
        defer response.deinit();
    }
}

const RetainsAllocator = struct {
    name: []const u8,
    age: u8,

    // Observe the allocator passed to the final parser. It must not refer to a
    // stack-local arena, even after returning and moving the owned result.
    pub var retained_allocator: ?std.mem.Allocator = null;

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const parsed = try std.json.innerParse(Person, allocator, source, options);
        retained_allocator = allocator;
        return .{ .name = parsed.name, .age = parsed.age };
    }
};

test "custom JSON parsers receive a stable allocator after the result moves" {
    var script: Script = .{ .case = .responses, .replies = &.{.{ .body = bodyFor(.responses, person_json), .structured = true }} };
    var original = blk: {
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        break :blk try client.extract(RetainsAllocator, .{ .prompt = "Robby is 24." });
    };
    var moved = original;
    original = undefined;
    defer moved.deinit();
    defer RetainsAllocator.retained_allocator = null;
    const allocated = try RetainsAllocator.retained_allocator.?.dupe(u8, "stable allocator context");
    try std.testing.expectEqualStrings("stable allocator context", allocated);
    try std.testing.expectEqualStrings("Robby", moved.value.name);
}

fn exerciseOwnedCalls(allocator: std.mem.Allocator) !void {
    var script: Script = .{ .case = .responses, .replies = &.{
        .{ .body = bodyFor(.responses, "Hello") },
        .{ .body = bodyFor(.responses, person_json), .structured = true },
    } };
    script.expected_custom_header = "custom";
    var config = configFor(allocator, &script);
    config.headers = &.{.{ .name = "X-App", .value = "custom" }};
    var client = try llm.Client.init(config);
    defer client.deinit();
    var response = try client.text("Say hello.");
    defer response.deinit();
    var person = try client.extract(Person, .{ .prompt = "Robby is 24." });
    defer person.deinit();
}

fn exerciseOwnedAllocationFailures(allocator: std.mem.Allocator) !void {
    exerciseOwnedCalls(allocator) catch |err| switch (err) {
        // The pinned schema emitter's allocating writer reports WriteFailed
        // on allocation failure. This scripted fixture performs no I/O writes.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}

test "owned completion and extraction release partial allocations on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnedAllocationFailures, .{});
}
