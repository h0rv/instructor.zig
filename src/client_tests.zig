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
    expected_max_tokens: ?u32 = null,
    expected_url: ?[]const u8 = null,
    inspect: ?*const fn (http.Request, std.json.Value) anyerror!void = null,

    fn transport(self: *Script) http.Transport {
        return .{ .ctx = self, .send_fn = send };
    }

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        if (self.calls >= self.replies.len) return error.UnexpectedRequest;
        const reply = self.replies[self.calls];
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        const path_end = std.mem.indexOfAny(u8, request.url, "?#") orelse request.url.len;
        if (self.expected_url) |expected| try std.testing.expectEqualStrings(expected, request.url);
        try std.testing.expect(std.mem.endsWith(u8, request.url[0..path_end], switch (self.case) {
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
        if (self.inspect) |inspect| try inspect(request, parsed.value);
        try std.testing.expectEqualStrings(self.expected_model, root.get("model").?.string);
        const format = switch (self.case) {
            .responses => if (root.get("text")) |text| text.object.get("format") else null,
            .chat => root.get("response_format"),
            .anthropic => if (root.get("output_config")) |config| config.object.get("format") else null,
        };
        try std.testing.expectEqual(reply.structured, format != null);
        if (self.expected_max_tokens) |maximum| {
            const key = if (self.case == .responses) "max_output_tokens" else "max_tokens";
            try std.testing.expectEqual(@as(i64, maximum), root.get(key).?.integer);
        }
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
        var reply = try client.responses.create(.{ .input = "Say hello." });
        defer reply.deinit();
        try std.testing.expectEqualStrings("Hello", reply.text);
        try std.testing.expectEqual(@as(u64, 5), reply.usage.total_tokens);

        var person = try client.responses.parse(Person, .{ .input = "Robby is 24." });
        defer person.deinit();
        try std.testing.expectEqualStrings("Robby", person.value.name);
        try std.testing.expectEqual(@as(u8, 24), person.value.age);
        try std.testing.expectEqual(@as(usize, 2), script.calls);
    }
}

test "Messages resource uses standard fields across every adapter" {
    inline for (cases) |case| {
        var script: Script = .{ .case = case, .expected_max_tokens = 64, .replies = &.{
            .{ .body = bodyFor(case, "Hello"), .message_count = 1 },
            .{ .body = bodyFor(case, person_json), .structured = true, .message_count = 1 },
            .{ .body = bodyFor(case, person_json), .structured = true, .message_count = 1 },
        } };
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        var reply = try client.messages.create(.{
            .messages = &.{.{ .role = .user, .content = "Say hello." }},
            .max_tokens = 64,
        });
        defer reply.deinit();
        try std.testing.expectEqualStrings("Hello", reply.text);

        var person = try client.messages.parse(Person, .{
            .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
            .max_tokens = 64,
        });
        defer person.deinit();
        try std.testing.expectEqualStrings("Robby", person.value.name);
        try std.testing.expectEqual(@as(u8, 24), person.value.age);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const scoped_person = try client.messages.parseInto(Person, arena.allocator(), .{
            .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
            .max_tokens = 64,
        });
        try std.testing.expectEqualStrings("Robby", scoped_person.name);
    }
}

test "resource fields remain valid across client moves and ad-hoc verbs are absent" {
    try std.testing.expect(!@hasDecl(llm.Client, "text"));
    try std.testing.expect(!@hasDecl(llm.Client, "complete"));
    try std.testing.expect(!@hasDecl(llm.Client, "extract"));
    var script: Script = .{ .case = .responses, .replies = &.{.{ .body = bodyFor(.responses, "Hello") }} };
    var original = try llm.Client.init(configFor(std.testing.allocator, &script));
    const saved_resource = original.responses;
    var moved = original;
    original = undefined;
    defer moved.deinit();
    var reply = try saved_resource.create(.{ .input = "Hello" });
    defer reply.deinit();
    try std.testing.expectEqualStrings("Hello", reply.text);
}

test "validation retries use the existing engine and keep cumulative usage" {
    inline for (cases) |case| {
        var script: Script = .{ .case = case, .replies = &.{
            .{ .body = bodyFor(case, "{\\\"name\\\":\\\"Robby\\\",\\\"age\\\":300}"), .structured = true, .message_count = 1 },
            .{ .body = bodyFor(case, person_json), .structured = true, .message_count = 3 },
        } };
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        var person = try client.responses.parse(Person, .{ .input = "Robby is 24." });
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
    return client.responses.parse(Person, .{ .input = "Robby is 24." });
}

fn completeAfterClientDies(allocator: std.mem.Allocator) !llm.Response {
    var script: Script = .{ .case = .responses, .replies = &.{.{ .body = bodyFor(.responses, "Hello") }} };
    var client = try llm.Client.init(configFor(allocator, &script));
    defer client.deinit();
    return client.responses.create(.{ .input = "Say hello." });
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
        break :blk try client.responses.parseIntoWith(Person, arena.allocator(), .{ .input = "Robby is 24." }, .{
            .parse_options = .{ .allocate = .alloc_if_needed },
        });
    };
    try std.testing.expectEqualStrings("Robby", saved.name);
    // Independently exercise an owned result with the same parse policy.
    var owned_script: Script = .{ .case = .responses, .replies = &.{.{ .body = bodyFor(.responses, person_json), .structured = true }} };
    var client = try llm.Client.init(configFor(std.testing.allocator, &owned_script));
    defer client.deinit();
    var person = try client.responses.parseWith(Person, .{ .input = "Robby is 24." }, .{ .parse_options = .{ .allocate = .alloc_if_needed } });
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
    try std.testing.expectEqualStrings("test-model", client._state.model);
    var override = "override-model".*;
    var response = try client.responses.create(.{ .input = "Hello", .model = &override });
    defer response.deinit();
    @memset(&override, 'x');
    try std.testing.expectEqualStrings("override-model", response.model);
}

test "input validation and unsupported controls fail without invoking transport" {
    var script: Script = .{ .case = .anthropic, .replies = &.{} };
    var client = try llm.Client.init(configFor(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.MissingInput, client.messages.create(.{ .messages = &.{} }));
    try std.testing.expectError(error.UnsupportedControl, client.responses.create(.{ .input = "Hello", .temperature = 0.5 }));
    try std.testing.expectError(error.InvalidMaxOutputTokens, client.responses.create(.{ .input = "Hello", .max_output_tokens = 0 }));
    try std.testing.expectError(error.MissingModel, client.responses.create(.{ .input = "Hello", .model = "" }));
    try std.testing.expectEqual(@as(usize, 0), script.calls);
}

test "message history is forwarded and failed requests retain diagnostics" {
    var script: Script = .{ .case = .chat, .replies = &.{.{ .body = "{\"error\":{\"message\":\"denied\"}}", .status = .forbidden, .message_count = 2 }} };
    var client = try llm.Client.init(configFor(std.testing.allocator, &script));
    defer client.deinit();
    try std.testing.expectError(error.ProviderHttpError, client.messages.create(.{
        .messages = &.{
            .{ .role = .assistant, .content = "Earlier reply" },
            .{ .role = .user, .content = "Continue" },
        },
    }));
    try std.testing.expectEqual(std.http.Status.forbidden, client.diagnostic().status.?);
    try std.testing.expect(client.diagnostic().body != null);
    try std.testing.expectError(error.MissingInput, client.messages.create(.{ .messages = &.{} }));
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
    var response = try client.responses.create(.{ .input = "Hello" });
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
        var response = try client.responses.create(.{ .input = "Hello" });
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
        break :blk try client.responses.parse(RetainsAllocator, .{ .input = "Robby is 24." });
    };
    var moved = original;
    original = undefined;
    defer moved.deinit();
    defer RetainsAllocator.retained_allocator = null;
    const allocated = try RetainsAllocator.retained_allocator.?.dupe(u8, "stable allocator context");
    try std.testing.expectEqualStrings("stable allocator context", allocated);
    try std.testing.expectEqualStrings("Robby", moved.value.name);
}

fn inspectPassthrough(request: http.Request, value: std.json.Value) !void {
    const root = value.object;
    const metadata = root.get("metadata").?.object;
    try std.testing.expectEqualStrings("copied", metadata.get("client").?.string);
    try std.testing.expectEqualStrings("request", metadata.get("shared").?.string);
    try std.testing.expect(root.get("new_option").?.bool);
    try std.testing.expectEqualStrings("high", root.get("text").?.object.get("verbosity").?.string);
    try std.testing.expect(std.mem.indexOf(u8, request.body.?, "123456789012345678901234567890123456789") != null);
}

test "client defaults and request extras reach every adapter without losing schemas" {
    inline for (cases) |case| {
        var script: Script = .{
            .case = case,
            .expected_custom_header = "request",
            .expected_url = (switch (case) {
                .responses => "https://api.openai.com/v1/responses",
                .chat => "https://api.openai.com/v1/chat/completions",
                .anthropic => "https://api.anthropic.com/v1/messages",
            }) ++ "?client-key=copied&shared=new%20%26%20yes&repeat=first&repeat=second",
            .inspect = inspectPassthrough,
            .replies = &.{
                .{ .body = bodyFor(case, "Hello") },
                .{ .body = bodyFor(case, person_json), .structured = true },
            },
        };
        var query_name = "client-key".*;
        var query_value = "copied".*;
        var client = blk: {
            const defaults = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
                \\{"metadata":{"client":"copied","shared":"default"},"big":123456789012345678901234567890123456789}
            , .{ .parse_numbers = false });
            defer defaults.deinit();
            var config = configFor(std.testing.allocator, &script);
            config.extra_body = defaults.value;
            config.extra_query = &.{
                .{ .name = &query_name, .value = &query_value },
                .{ .name = "shared", .value = "default" },
            };
            config.headers = &.{.{ .name = "X-App", .value = "default" }};
            break :blk try llm.Client.init(config);
        };
        defer client.deinit();
        @memset(&query_name, 'x');
        @memset(&query_value, 'x');

        const extra = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
            \\{"metadata":{"shared":"request"},"new_option":true,"text":{"verbosity":"high"}}
        , .{});
        defer extra.deinit();
        const headers: []const std.http.Header = &.{.{ .name = "x-app", .value = "request" }};
        const query: []const llm.QueryParam = &.{
            .{ .name = "shared", .value = "new & yes" },
            .{ .name = "repeat", .value = "first" },
            .{ .name = "repeat", .value = "second" },
        };
        var reply = try client.responses.create(.{
            .input = "Hello",
            .extra_body = extra.value,
            .extra_headers = headers,
            .extra_query = query,
        });
        defer reply.deinit();
        var person = try client.messages.parse(Person, .{
            .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
            .extra_body = extra.value,
            .extra_headers = headers,
            .extra_query = query,
        });
        defer person.deinit();
        try std.testing.expectEqualStrings("Robby", person.value.name);
        try std.testing.expectEqual(@as(usize, 2), script.calls);
    }
}

test "request extras cannot replace routing or Instructor schemas or enable streaming" {
    inline for (cases) |case| {
        var script: Script = .{ .case = case, .replies = &.{} };
        var client = try llm.Client.init(configFor(std.testing.allocator, &script));
        defer client.deinit();
        const routing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"model\":\"other\"}", .{});
        defer routing.deinit();
        try std.testing.expectError(error.ReservedBodyField, client.responses.create(.{ .input = "Hello", .extra_body = routing.value }));
        const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, switch (case) {
            .responses => "{\"text\":{\"format\":{\"type\":\"text\"}}}",
            .chat => "{\"response_format\":{\"type\":\"text\"}}",
            .anthropic => "{\"output_config\":{\"format\":{\"type\":\"text\"}}}",
        }, .{});
        defer schema.deinit();
        try std.testing.expectError(error.ReservedBodyField, client.responses.parse(Person, .{ .input = "Robby is 24.", .extra_body = schema.value }));
        const streaming = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"stream\":true}", .{});
        defer streaming.deinit();
        try std.testing.expectError(error.UnsupportedStreaming, client.responses.create(.{ .input = "Hello", .extra_body = streaming.value }));
        try std.testing.expectError(error.InvalidExtraBody, client.responses.create(.{ .input = "Hello", .extra_body = .null }));
        try std.testing.expectEqual(@as(usize, 0), script.calls);
    }
}

fn exerciseOwnedCalls(allocator: std.mem.Allocator) !void {
    var script: Script = .{ .case = .responses, .replies = &.{
        .{ .body = bodyFor(.responses, "Hello") },
        .{ .body = bodyFor(.responses, person_json), .structured = true },
    } };
    script.expected_custom_header = "custom";
    const defaults = try std.json.parseFromSlice(std.json.Value, allocator, "{\"metadata\":{\"source\":\"client\"}}", .{});
    defer defaults.deinit();
    const extra = try std.json.parseFromSlice(std.json.Value, allocator, "{\"metadata\":{\"request\":true}}", .{});
    defer extra.deinit();
    var config = configFor(allocator, &script);
    config.headers = &.{.{ .name = "X-App", .value = "custom" }};
    config.extra_body = defaults.value;
    config.extra_query = &.{.{ .name = "route", .value = "default" }};
    var client = try llm.Client.init(config);
    defer client.deinit();
    var response = try client.responses.create(.{
        .input = "Say hello.",
        .extra_body = extra.value,
        .extra_headers = &.{.{ .name = "x-app", .value = "custom" }},
        .extra_query = &.{.{ .name = "route", .value = "request" }},
    });
    defer response.deinit();
    var person = try client.responses.parse(Person, .{
        .input = "Robby is 24.",
        .extra_body = extra.value,
        .extra_headers = &.{.{ .name = "x-app", .value = "custom" }},
        .extra_query = &.{.{ .name = "route", .value = "request" }},
    });
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
    // Force arena growth through allocation, not address-dependent resize/remap.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), exerciseOwnedAllocationFailures, .{});
}
