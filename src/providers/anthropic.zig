const std = @import("std");
const anthropic = @import("anthropic");
const jsonschema = @import("jsonschema");
const types = @import("../core/types.zig");
const Options = @import("../core/options.zig").Options;
const transport_api = @import("../transport.zig");

pub const api = anthropic;

/// Anthropic's remote schema subset. Explicit field constraints still apply locally.
pub const anthropic_schema_options: jsonschema.Options = blk: {
    var options = jsonschema.strict_options;
    options.infer_integer_bounds = false;
    options.infer_fixed_array_bounds = false;
    options.use_defs = .never;
    break :blk options;
};

pub const Client = struct {
    pub const default_model = "claude-sonnet-4-6";
    pub const Api = anthropic;

    allocator: std.mem.Allocator,
    sdk: anthropic.Client,
    api_key: []const u8,
    max_tokens: u32,
    /// Borrowed. The caller owns the transport context and its cleanup.
    transport: ?transport_api.Transport,
    max_response_bytes: usize,
    last_status: ?std.http.Status = null,
    last_error_body: ?[]u8 = null,

    pub const Error = error{
        ProviderHttpError,
        MissingOutputText,
        InvalidProviderResponse,
        UnsupportedMode,
        UnsupportedImages,
        UnsupportedSchema,
        UnsupportedSchemaReference,
        InvalidMaxTokens,
        Refusal,
        MaxTokensExceeded,
        IncompleteResponse,
    };

    pub const Config = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        api_key: []const u8,
        base_url: []const u8 = "https://api.anthropic.com",
        /// Required by /messages. A request can override this default.
        max_tokens: u32 = 4096,
        transport: ?transport_api.Transport = null,
        max_response_bytes: usize = 8 * 1024 * 1024,
    };

    /// Native Messages request. Sampling controls removed in API 2026-10-21
    /// are deliberately not exposed. This is not an OpenAI request alias.
    pub const Request = struct {
        model: []const u8,
        messages: []const Message,
        max_tokens: ?u32 = null,
        owned_retry_messages: usize = 0,

        pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
            if (self.owned_retry_messages == 0) return;
            const start = self.messages.len - self.owned_retry_messages;
            for (self.messages[start..]) |message| allocator.free(message.content);
            allocator.free(self.messages);
            self.messages = &.{};
            self.owned_retry_messages = 0;
        }
    };

    pub const Message = struct {
        role: Role,
        content: []const u8,
        /// Images are rejected explicitly until native image blocks are supported.
        images: []const Image = &.{},
    };
    pub const Image = struct { url: []const u8 };
    pub const Role = enum { system, user, assistant };

    pub fn init(config: Config) Client {
        var sdk = anthropic.Client.init(config.allocator, config.io, "");
        sdk.withBaseUrl(config.base_url);
        sdk.default_headers = &.{.{ .name = "anthropic-version", .value = "2026-10-21" }};
        return .{
            .allocator = config.allocator,
            .sdk = sdk,
            .api_key = config.api_key,
            .max_tokens = config.max_tokens,
            .transport = config.transport,
            .max_response_bytes = config.max_response_bytes,
        };
    }

    pub fn deinit(self: *Client) void {
        self.clearLastError();
        self.sdk.deinit();
    }

    pub fn clearLastError(self: *Client) void {
        if (self.last_error_body) |body| self.allocator.free(body);
        self.last_error_body = null;
        self.last_status = null;
    }

    pub fn lastStatus(self: *const Client) ?std.http.Status {
        return self.last_status;
    }

    pub fn lastErrorBody(self: *const Client) ?[]const u8 {
        return self.last_error_body;
    }

    pub fn diagnostic(self: *const Client) types.Diagnostic {
        return .{ .provider = "anthropic", .status = self.last_status, .body = self.last_error_body };
    }

    pub fn completeStructured(
        self: *Client,
        allocator: std.mem.Allocator,
        request: Request,
        schema: types.StructuredSchema,
        comptime options: Options,
    ) !types.Completion {
        self.clearLastError();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const body = try buildRequest(arena.allocator(), request, schema, options.mode, self.max_tokens);
        return self.dispatch(allocator, arena.allocator(), body, options.mode, schema.name);
    }

    /// Ordinary Messages completion, with no schema or tool configuration.
    pub fn completeText(self: *Client, allocator: std.mem.Allocator, request: Request) !types.Completion {
        self.clearLastError();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const body = try buildBaseRequest(arena.allocator(), request, self.max_tokens);
        // json_schema selects the existing text-block decoder, not a wire mode.
        return self.dispatch(allocator, arena.allocator(), body, .json_schema, "");
    }

    fn dispatch(self: *Client, allocator: std.mem.Allocator, scratch: std.mem.Allocator, body: Value, mode: types.Mode, name: []const u8) !types.Completion {
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.appendSlice(scratch, self.sdk.default_headers);
        var has_key = false;
        var has_version = false;
        for (headers.items) |*header| {
            if (std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) has_version = true;
            if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                header.value = self.api_key;
                has_key = true;
            }
        }
        if (!has_key) try headers.append(scratch, .{ .name = "x-api-key", .value = self.api_key });
        if (!has_version) try headers.append(scratch, .{ .name = "anthropic-version", .value = "2026-10-21" });
        if (self.transport) |transport| {
            // JSON content type is authoritative even if defaults contain one.
            var has_content_type = false;
            for (headers.items) |*header| {
                if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                    header.value = "application/json";
                    has_content_type = true;
                }
            }
            if (!has_content_type) try headers.append(scratch, .{ .name = "content-type", .value = "application/json" });
            const payload = try std.json.Stringify.valueAlloc(scratch, body, .{});
            const url = try scratch.print("{s}/v1/messages", .{std.mem.trimEnd(u8, self.sdk.base_url, "/")});
            var raw = try transport.send(self.sdk.io, allocator, .{
                .method = .POST,
                .url = url,
                .headers = headers.items,
                .body = payload,
                .max_response_bytes = self.max_response_bytes,
            });
            defer raw.deinit();
            return self.receive(allocator, raw.status, raw.body, mode, name);
        }
        // Keep SDK observers and low-level callers working when no transport is injected.
        const previous_headers = self.sdk.default_headers;
        self.sdk.default_headers = headers.items;
        defer self.sdk.default_headers = previous_headers;
        var raw = try anthropic.postJsonRaw(&self.sdk, "/v1/messages", body);
        defer raw.deinit();
        return self.receive(allocator, raw.status, raw.body, mode, name);
    }

    fn receive(
        self: *Client,
        allocator: std.mem.Allocator,
        status: std.http.Status,
        body: []const u8,
        mode: types.Mode,
        name: []const u8,
    ) !types.Completion {
        self.clearLastError();
        self.last_status = status;
        return parseCompletion(allocator, status, body, mode, name) catch |err| {
            self.last_error_body = try self.allocator.dupe(u8, body);
            return err;
        };
    }

    pub fn appendRetry(self: *Client, allocator: std.mem.Allocator, request: *Request, retry: types.RetryMessage) !void {
        _ = self;
        const failed = try allocator.dupe(u8, retry.failed_response);
        errdefer allocator.free(failed);
        const feedback = try allocator.dupe(u8, retry.error_message);
        errdefer allocator.free(feedback);
        const messages = try allocator.alloc(Message, request.messages.len + 2);
        errdefer allocator.free(messages);
        @memcpy(messages[0..request.messages.len], request.messages);
        // Use text feedback, not fabricated tool_use/tool_result identifiers.
        messages[request.messages.len] = .{ .role = .assistant, .content = failed };
        messages[request.messages.len + 1] = .{ .role = .user, .content = feedback };
        if (request.owned_retry_messages != 0) allocator.free(request.messages);
        request.messages = messages;
        request.owned_retry_messages += 2;
    }

    pub fn deinitRequest(self: *Client, allocator: std.mem.Allocator, request: *Request) void {
        _ = self;
        request.deinit(allocator);
    }
};

const Value = std.json.Value;

fn string(value: []const u8) Value {
    return .{ .string = value };
}

fn object(allocator: std.mem.Allocator, keys: []const []const u8, values: []const Value) !Value {
    var result: Value = .{ .object = .empty };
    for (keys, values) |key, value| try result.object.put(allocator, key, value);
    return result;
}

/// All intermediate JSON values borrow strings and live in the caller's arena.
fn buildBaseRequest(allocator: std.mem.Allocator, request: Client.Request, default_max_tokens: u32) !Value {
    const max_tokens = request.max_tokens orelse default_max_tokens;
    if (max_tokens == 0) return Client.Error.InvalidMaxTokens;
    var messages: Value = .{ .array = .init(allocator) };
    var system: Value = .{ .array = .init(allocator) };
    for (request.messages) |message| {
        if (message.images.len != 0) return Client.Error.UnsupportedImages;
        if (message.role == .system) {
            try system.array.append(try object(allocator, &.{ "type", "text" }, &.{ string("text"), string(message.content) }));
        } else {
            try messages.array.append(try object(allocator, &.{ "role", "content" }, &.{ string(@tagName(message.role)), string(message.content) }));
        }
    }
    var body = try object(allocator, &.{ "model", "max_tokens", "messages" }, &.{
        string(request.model), .{ .integer = max_tokens }, messages,
    });
    if (system.array.items.len != 0) try body.object.put(allocator, "system", system);
    return body;
}

fn buildRequest(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    mode: types.Mode,
    default_max_tokens: u32,
) !Value {
    switch (mode) {
        .json_schema, .tool_call, .tool_call_required => {},
        .json_object, .responses_tool_call, .responses_tool_call_required => return Client.Error.UnsupportedMode,
    }
    var body = try buildBaseRequest(allocator, request, default_max_tokens);
    const original = try std.json.parseFromSliceLeaky(Value, allocator, schema.schema_json, .{
        .duplicate_field_behavior = .use_last,
    });
    const remote_schema = try remoteSchema(allocator, original, 0);
    if (remote_schema != .object or !isString(remote_schema.object.get("type"), "object")) return Client.Error.UnsupportedSchema;
    switch (mode) {
        .json_schema => {
            const format = try object(allocator, &.{ "type", "schema" }, &.{ string("json_schema"), remote_schema });
            try body.object.put(allocator, "output_config", try object(allocator, &.{"format"}, &.{format}));
        },
        .tool_call, .tool_call_required => {
            var tool = try object(allocator, &.{ "name", "input_schema", "strict" }, &.{ string(schema.name), remote_schema, .{ .bool = true } });
            if (schema.description) |description| try tool.object.put(allocator, "description", string(description));
            var tools: Value = .{ .array = .init(allocator) };
            try tools.array.append(tool);
            try body.object.put(allocator, "tools", tools);
            // Forced tool use is model-dependent and only enabled explicitly.
            if (mode == .tool_call_required) {
                try body.object.put(allocator, "tool_choice", try object(allocator, &.{ "type", "name" }, &.{ string("tool"), string(schema.name) }));
            }
        },
        else => unreachable,
    }
    return body;
}

/// Relax only schema keywords, never user property names or enum/const data.
/// The original schema remains untouched for core's parse/validation retries.
/// References (including recursive schemas) and unknown applicators are rejected.
fn remoteSchema(allocator: std.mem.Allocator, value: Value, depth: usize) (std.mem.Allocator.Error || Client.Error)!Value {
    if (depth > 128 or value != .object) return Client.Error.UnsupportedSchema;
    var result: Value = .{ .object = .empty };
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const child = entry.value_ptr.*;
        if (oneOf(key, &.{ "$ref", "$defs", "definitions", "$dynamicRef", "$recursiveRef" })) return Client.Error.UnsupportedSchemaReference;
        if (oneOf(key, &.{
            "minimum",   "maximum",   "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
            "minLength", "maxLength", "minItems",         "maxItems",         "uniqueItems",
            "$schema",   "default",   "examples",         "$comment",
        })) continue;
        const transformed = if (std.mem.eql(u8, key, "properties")) blk: {
            if (child != .object) return Client.Error.UnsupportedSchema;
            var properties: Value = .{ .object = .empty };
            var fields = child.object.iterator();
            while (fields.next()) |field| {
                try properties.object.put(allocator, field.key_ptr.*, try remoteSchema(allocator, field.value_ptr.*, depth + 1));
            }
            break :blk properties;
        } else if (std.mem.eql(u8, key, "items"))
            try remoteSchema(allocator, child, depth + 1)
        else if (std.mem.eql(u8, key, "anyOf")) blk: {
            if (child != .array or child.array.items.len == 0) return Client.Error.UnsupportedSchema;
            var alternatives: Value = .{ .array = .init(allocator) };
            for (child.array.items) |item| try alternatives.array.append(try remoteSchema(allocator, item, depth + 1));
            break :blk alternatives;
        } else if (std.mem.eql(u8, key, "additionalProperties")) blk: {
            if (child != .bool or child.bool) return Client.Error.UnsupportedSchema;
            break :blk child;
        } else if (oneOf(key, &.{ "type", "required", "enum", "const", "description", "title", "pattern", "format" }))
            child
        else
            return Client.Error.UnsupportedSchema;
        try result.object.put(allocator, key, transformed);
    }
    return result;
}

fn oneOf(key: []const u8, keys: []const []const u8) bool {
    for (keys) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn isString(value: ?Value, expected: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}

fn parseCompletion(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8, mode: types.Mode, name: []const u8) !types.Completion {
    if (status.class() != .success) return Client.Error.ProviderHttpError;
    const parsed = std.json.parseFromSlice(Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return Client.Error.InvalidProviderResponse,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return Client.Error.InvalidProviderResponse;
    if (root.object.get("error") != null or isString(root.object.get("type"), "error")) return Client.Error.ProviderHttpError;
    const stop = root.object.get("stop_reason");
    if (isString(stop, "refusal")) return Client.Error.Refusal;
    if (isString(stop, "max_tokens")) return Client.Error.MaxTokensExceeded;
    if (isString(stop, "pause_turn") or isString(stop, "model_context_window_exceeded")) return Client.Error.IncompleteResponse;
    const content = root.object.get("content") orelse return Client.Error.InvalidProviderResponse;
    if (content != .array) return Client.Error.InvalidProviderResponse;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var input: ?Value = null;
    for (content.array.items) |block| {
        if (block != .object) return Client.Error.InvalidProviderResponse;
        const kind = block.object.get("type");
        if (isString(kind, "refusal")) return Client.Error.Refusal;
        if (mode == .json_schema and isString(kind, "text")) {
            const part = block.object.get("text") orelse return Client.Error.InvalidProviderResponse;
            if (part != .string) return Client.Error.InvalidProviderResponse;
            try text.appendSlice(allocator, part.string);
        } else if ((mode == .tool_call or mode == .tool_call_required) and isString(kind, "tool_use")) {
            if (!isString(block.object.get("name"), name)) return Client.Error.InvalidProviderResponse;
            if (input != null) return Client.Error.InvalidProviderResponse;
            const arguments = block.object.get("input") orelse return Client.Error.InvalidProviderResponse;
            // Native tool inputs are objects, never JSON-encoded strings.
            if (arguments != .object) return Client.Error.InvalidProviderResponse;
            input = arguments;
        }
    }
    const usage = try usageFromValue(root);
    const output = if (mode == .json_schema) blk: {
        if (text.items.len == 0) return Client.Error.MissingOutputText;
        break :blk try text.toOwnedSlice(allocator);
    } else blk: {
        const arguments = input orelse return Client.Error.MissingOutputText;
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        std.json.Stringify.value(arguments, .{}, &writer.writer) catch return error.OutOfMemory;
        break :blk try writer.toOwnedSlice();
    };
    errdefer allocator.free(output);
    return .{ .text = output, .raw_response = try allocator.dupe(u8, body), .usage = usage };
}

fn usageFromValue(root: Value) !types.Usage {
    const value = root.object.get("usage") orelse return .{};
    if (value != .object) return Client.Error.InvalidProviderResponse;
    // Anthropic reports cache tokens separately from uncached input tokens.
    const input = std.math.add(u64, try tokenCount(value, "input_tokens"), try tokenCount(value, "cache_creation_input_tokens")) catch return Client.Error.InvalidProviderResponse;
    const all_input = std.math.add(u64, input, try tokenCount(value, "cache_read_input_tokens")) catch return Client.Error.InvalidProviderResponse;
    const output = try tokenCount(value, "output_tokens");
    return .{
        .input_tokens = all_input,
        .output_tokens = output,
        .total_tokens = std.math.add(u64, all_input, output) catch return Client.Error.InvalidProviderResponse,
    };
}

fn tokenCount(value: Value, key: []const u8) !u64 {
    const count = value.object.get(key) orelse return 0;
    if (count != .integer or count.integer < 0) return Client.Error.InvalidProviderResponse;
    return @intCast(count.integer);
}

const test_schema: types.StructuredSchema = .{
    .name = "Person",
    .description = "Extract a person.",
    .schema_json = "{\"type\":\"object\",\"properties\":{\"age\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":130}},\"required\":[\"age\"],\"additionalProperties\":false}",
};
const test_request: Client.Request = .{
    .model = Client.default_model,
    .messages = &.{
        .{ .role = .system, .content = "Extract the person." },
        .{ .role = .user, .content = "Ada is 42." },
        .{ .role = .system, .content = "Preserve the name." },
    },
};
const test_text_response =
    \\{"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"ignore me"},{"type":"text","text":"{\"age\":"},{"type":"text","text":"42}"}],"usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":2,"cache_read_input_tokens":1}}
;
const test_tool_response =
    \\{"type":"message","stop_reason":"tool_use","content":[{"type":"text","text":"Using the tool."},{"type":"tool_use","id":"toolu_1","name":"Person","input":{"age":42}}],"usage":{"input_tokens":3,"output_tokens":4}}
;

fn testClient(allocator: std.mem.Allocator) Client {
    return Client.init(.{ .allocator = allocator, .io = std.testing.io, .api_key = "offline" });
}

fn remoteFromBody(body: Value) Value {
    return body.object.get("output_config").?.object.get("format").?.object.get("schema").?;
}

test "anthropic sends API keys through x-api-key and preserves custom headers" {
    const Observer = struct {
        seen: bool = false,
        failure: ?anyerror = null,

        fn request(ctx: ?*anyopaque, _: std.http.Method, url: []const u8, headers: []const std.http.Header, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.seen = true;
            self.check(url, headers) catch |err| {
                self.failure = err;
            };
        }

        fn check(_: *@This(), url: []const u8, headers: []const std.http.Header) !void {
            try std.testing.expectEqualStrings("offline://anthropic/v1/messages", url);
            var keys: usize = 0;
            var versions: usize = 0;
            var custom: usize = 0;
            for (headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                    keys += 1;
                    try std.testing.expectEqualStrings("offline", header.value);
                }
                if (std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) versions += 1;
                if (std.ascii.eqlIgnoreCase(header.name, "anthropic-beta")) custom += 1;
                try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "authorization"));
            }
            try std.testing.expectEqual(@as(usize, 1), keys);
            try std.testing.expectEqual(@as(usize, 1), versions);
            try std.testing.expectEqual(@as(usize, 1), custom);
        }
    };
    var client = testClient(std.testing.allocator);
    defer client.deinit();
    client.sdk.withBaseUrl("offline://anthropic");
    const defaults = [_]std.http.Header{
        .{ .name = "anthropic-version", .value = "2026-10-21" },
        .{ .name = "anthropic-beta", .value = "example" },
    };
    client.sdk.default_headers = &defaults;
    var observer = Observer{};
    client.sdk.http_observer = .{ .ctx = &observer, .onRequest = Observer.request, .onResponse = null, .onError = null };
    try std.testing.expectError(error.UnsupportedUriScheme, client.completeStructured(std.testing.allocator, test_request, test_schema, .{}));
    try std.testing.expect(observer.seen);
    if (observer.failure) |err| return err;
    try std.testing.expectEqual(@intFromPtr(&defaults), @intFromPtr(client.sdk.default_headers.ptr));
}

test "anthropic native request shape and top-level system blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildRequest(arena.allocator(), test_request, test_schema, .json_schema, 1024);
    try std.testing.expectEqual(@as(i64, 1024), body.object.get("max_tokens").?.integer);
    const messages = body.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(isString(messages[0].object.get("role"), "user"));
    const system = body.object.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), system.len);
    try std.testing.expect(isString(system[0].object.get("type"), "text"));
    try std.testing.expect(isString(system[0].object.get("text"), "Extract the person."));
    try std.testing.expect(isString(system[1].object.get("text"), "Preserve the name."));
    try std.testing.expect(body.object.get("temperature") == null);
    try std.testing.expect(body.object.get("top_p") == null);
    try std.testing.expect(body.object.get("response_format") == null);
    try std.testing.expect(isString(body.object.get("output_config").?.object.get("format").?.object.get("type"), "json_schema"));
    try std.testing.expect(remoteFromBody(body) == .object);
    try std.testing.expect(remoteFromBody(body).object.get("properties").?.object.get("age").?.object.get("minimum") == null);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"schema\":{\"type\":\"object\"") != null);
    var request = test_request;
    request.max_tokens = 512;
    const override = try buildRequest(arena.allocator(), request, test_schema, .json_schema, 1024);
    try std.testing.expectEqual(@as(i64, 512), override.object.get("max_tokens").?.integer);
}

test "anthropic strict tools only force tool choice when explicitly requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ types.Mode.tool_call, types.Mode.tool_call_required }) |mode| {
        const body = try buildRequest(arena.allocator(), test_request, test_schema, mode, 1024);
        const tool = body.object.get("tools").?.array.items[0];
        try std.testing.expect(isString(tool.object.get("name"), "Person"));
        try std.testing.expect(tool.object.get("strict").?.bool);
        try std.testing.expect(tool.object.get("input_schema").? == .object);
        try std.testing.expect(body.object.get("output_config") == null);
        if (mode == .tool_call_required) {
            const choice = body.object.get("tool_choice").?;
            try std.testing.expect(isString(choice.object.get("type"), "tool"));
            try std.testing.expect(isString(choice.object.get("name"), "Person"));
        } else try std.testing.expect(body.object.get("tool_choice") == null);
    }
}

test "anthropic schema transformation visits schema positions not property names or const data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const original = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"type":"object","properties":{"minimum":{"type":"integer","minimum":0,"maximum":10,"exclusiveMinimum":-1,"exclusiveMaximum":11,"multipleOf":2},"minLength":{"type":"string","minLength":1,"maxLength":5},"minItems":{"type":"array","minItems":1,"maxItems":2,"uniqueItems":true,"items":{"anyOf":[{"type":"integer","minimum":0},{"type":"null"}]}},"const":{"const":{"minimum":7,"minLength":9}},"enum":{"enum":[{"minimum":8}]}}}
    , .{});
    const remote = try remoteSchema(arena.allocator(), original, 0);
    const properties = remote.object.get("properties").?.object;
    try std.testing.expectEqual(@as(usize, 5), properties.count());
    try std.testing.expectEqual(@as(usize, 1), properties.get("minimum").?.object.count());
    try std.testing.expectEqual(@as(usize, 1), properties.get("minLength").?.object.count());
    const array = properties.get("minItems").?.object;
    try std.testing.expectEqual(@as(usize, 2), array.count());
    try std.testing.expect(array.get("items").?.object.get("anyOf").?.array.items[0].object.get("minimum") == null);
    try std.testing.expectEqual(@as(i64, 7), properties.get("const").?.object.get("const").?.object.get("minimum").?.integer);
    try std.testing.expectEqual(@as(i64, 8), properties.get("enum").?.object.get("enum").?.array.items[0].object.get("minimum").?.integer);
    try std.testing.expect(original.object.get("properties").?.object.get("minimum").?.object.get("minimum") != null);
}

test "anthropic rejects unsupported modes images references and schema applicators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ types.Mode.json_object, types.Mode.responses_tool_call, types.Mode.responses_tool_call_required }) |mode| {
        try std.testing.expectError(error.UnsupportedMode, buildRequest(arena.allocator(), test_request, test_schema, mode, 1024));
    }
    var request = test_request;
    request.max_tokens = 0;
    try std.testing.expectError(error.InvalidMaxTokens, buildRequest(arena.allocator(), request, test_schema, .json_schema, 1024));
    request = .{ .model = Client.default_model, .messages = &.{.{ .role = .system, .content = "image", .images = &.{.{ .url = "https://example.com/image.png" }} }} };
    try std.testing.expectError(error.UnsupportedImages, buildRequest(arena.allocator(), request, test_schema, .json_schema, 1024));
    inline for (.{
        "{\"$ref\":\"#\"}",
        "{\"type\":\"object\",\"properties\":{\"child\":{\"$ref\":\"#\"}}}",
        "{\"$defs\":{\"node\":{\"$ref\":\"#/$defs/node\"}}}",
    }) |schema| {
        const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), schema, .{});
        try std.testing.expectError(error.UnsupportedSchemaReference, remoteSchema(arena.allocator(), value, 0));
    }
    inline for (.{ "{\"oneOf\":[]}", "{\"allOf\":[]}", "{\"prefixItems\":[]}", "{\"additionalProperties\":true}", "{\"items\":false}" }) |schema| {
        const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), schema, .{});
        try std.testing.expectError(error.UnsupportedSchema, remoteSchema(arena.allocator(), value, 0));
    }
}

test "anthropic text blocks concatenate and tool inputs serialize as objects" {
    var text = try parseCompletion(std.testing.allocator, .ok, test_text_response, .json_schema, "Person");
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"age\":42}", text.text);
    try std.testing.expectEqualStrings(test_text_response, text.raw_response);
    try std.testing.expectEqual(@as(u64, 6), text.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 4), text.usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 10), text.usage.total_tokens);
    var tool = try parseCompletion(std.testing.allocator, .ok, test_tool_response, .tool_call, "Person");
    defer tool.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"age\":42}", tool.text);
    try std.testing.expectEqual(@as(u64, 7), tool.usage.total_tokens);
    try std.testing.expectError(error.InvalidProviderResponse, parseCompletion(std.testing.allocator, .ok,
        \\{"content":[{"type":"tool_use","name":"Person","input":"{\"age\":42}"}]}
    , .tool_call, "Person"));
    try std.testing.expectError(error.InvalidProviderResponse, parseCompletion(std.testing.allocator, .ok, test_tool_response, .tool_call, "OtherTool"));
    try std.testing.expectError(error.MissingOutputText, parseCompletion(std.testing.allocator, .ok, test_text_response, .tool_call, "Person"));
}

test "anthropic detects refusals truncation and errors even with HTTP 200" {
    inline for (.{
        .{ "{\"stop_reason\":\"refusal\",\"content\":[]}", error.Refusal },
        .{ "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"text\",\"text\":\"{}\"}]}", error.MaxTokensExceeded },
        .{ "{\"stop_reason\":\"pause_turn\",\"content\":[]}", error.IncompleteResponse },
        .{ "{\"content\":[{\"type\":\"refusal\"}]}", error.Refusal },
        .{ "{\"error\":{\"type\":\"overloaded_error\"}}", error.ProviderHttpError },
        .{ "not json", error.InvalidProviderResponse },
        .{ "{\"content\":[]}", error.MissingOutputText },
        .{ "{\"content\":[{\"type\":\"text\",\"text\":\"{}\"}],\"usage\":{\"input_tokens\":-1}}", error.InvalidProviderResponse },
    }) |case| {
        var client = testClient(std.testing.allocator);
        defer client.deinit();
        try std.testing.expectError(case[1], client.receive(std.testing.allocator, .ok, case[0], .json_schema, "Person"));
        try std.testing.expectEqual(std.http.Status.ok, client.lastStatus().?);
        try std.testing.expectEqualStrings(case[0], client.lastErrorBody().?);
        try std.testing.expectEqualStrings("anthropic", client.diagnostic().provider);
    }
    var client = testClient(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectError(error.ProviderHttpError, client.receive(std.testing.allocator, .too_many_requests, "rate limited", .json_schema, "Person"));
    try std.testing.expectEqual(std.http.Status.too_many_requests, client.lastStatus().?);
    try std.testing.expectEqualStrings("rate limited", client.lastErrorBody().?);
    var completion = try client.receive(std.testing.allocator, .ok, test_text_response, .json_schema, "Person");
    defer completion.deinit(std.testing.allocator);
    try std.testing.expect(client.lastErrorBody() == null);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var client = testClient(allocator);
    defer client.deinit();
    var request = test_request;
    defer client.deinitRequest(allocator, &request);
    try client.appendRetry(allocator, &request, .{ .failed_response = "{}", .error_message = "age is required" });
    try client.appendRetry(allocator, &request, .{ .failed_response = "{\"age\":200}", .error_message = "age must be <= 130" });
    try std.testing.expectEqual(@as(usize, 4), request.owned_retry_messages);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try buildRequest(arena.allocator(), request, test_schema, .json_schema, 1024);
    _ = try buildRequest(arena.allocator(), request, test_schema, .tool_call_required, 1024);
    var text = try client.receive(allocator, .ok, test_text_response, .json_schema, "Person");
    defer text.deinit(allocator);
    var tool = try client.receive(allocator, .ok, test_tool_response, .tool_call_required, "Person");
    defer tool.deinit(allocator);
    _ = client.receive(allocator, .bad_request, "bad request body", .json_schema, "Person") catch |err| switch (err) {
        error.ProviderHttpError => return,
        else => return err,
    };
    return error.ExpectedProviderError;
}

test "anthropic allocation failure cleanup for request retries responses and diagnostics" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

const FakeTransport = struct {
    calls: usize = 0,
    response: []const u8 = test_text_response,
    status: std.http.Status = .ok,
    failure: ?anyerror = null,
    model: []const u8 = Client.default_model,
    max_tokens: u32 = 4096,
    system_count: usize = 2,
    mode: ?types.Mode = null,
    version: []const u8 = "2026-10-21",
    beta: ?[]const u8 = null,
    limit: usize = 8 * 1024 * 1024,

    fn transport(self: *@This()) transport_api.Transport {
        return .{ .ctx = self, .send_fn = send };
    }

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: transport_api.Request) !transport_api.Response {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        try std.testing.expectEqualStrings("offline://anthropic/v1/messages", request.url);
        try std.testing.expectEqual(self.limit, request.max_response_bytes);
        var keys: usize = 0;
        var versions: usize = 0;
        var content_types: usize = 0;
        var betas: usize = 0;
        for (request.headers) |header| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "authorization"));
            if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                keys += 1;
                try std.testing.expectEqualStrings("offline", header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) {
                versions += 1;
                try std.testing.expectEqualStrings(self.version, header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                content_types += 1;
                try std.testing.expectEqualStrings("application/json", header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "anthropic-beta")) {
                betas += 1;
                try std.testing.expectEqualStrings(self.beta.?, header.value);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), keys);
        try std.testing.expectEqual(@as(usize, 1), versions);
        try std.testing.expectEqual(@as(usize, 1), content_types);
        try std.testing.expectEqual(@as(usize, if (self.beta != null) 1 else 0), betas);
        const parsed = try std.json.parseFromSlice(Value, allocator, request.body.?, .{});
        defer parsed.deinit();
        const body = parsed.value;
        try std.testing.expect(isString(body.object.get("model"), self.model));
        try std.testing.expectEqual(@as(i64, self.max_tokens), body.object.get("max_tokens").?.integer);
        const messages = body.object.get("messages").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), messages.len);
        try std.testing.expect(isString(messages[0].object.get("role"), "user"));
        try std.testing.expect(isString(messages[0].object.get("content"), "Ada is 42."));
        if (self.system_count == 0) {
            try std.testing.expect(body.object.get("system") == null);
        } else {
            const system = body.object.get("system").?.array.items;
            try std.testing.expectEqual(self.system_count, system.len);
            try std.testing.expect(isString(system[0].object.get("text"), "Extract the person."));
            try std.testing.expect(isString(system[1].object.get("text"), "Preserve the name."));
        }
        if (self.mode) |mode| {
            const remote = if (mode == .json_schema) remoteFromBody(body) else body.object.get("tools").?.array.items[0].object.get("input_schema").?;
            try std.testing.expect(remote.object.get("properties").?.object.get("age").?.object.get("maximum") == null);
            if (mode == .json_schema) {
                try std.testing.expect(body.object.get("tools") == null);
                try std.testing.expect(body.object.get("tool_choice") == null);
            } else {
                try std.testing.expect(body.object.get("output_config") == null);
                const tool = body.object.get("tools").?.array.items[0];
                try std.testing.expect(isString(tool.object.get("name"), "Person"));
                try std.testing.expect(tool.object.get("strict").?.bool);
                try std.testing.expectEqual(mode == .tool_call_required, body.object.get("tool_choice") != null);
            }
        } else {
            try std.testing.expect(body.object.get("output_config") == null);
            try std.testing.expect(body.object.get("tools") == null);
            try std.testing.expect(body.object.get("tool_choice") == null);
        }
        if (self.failure) |err| return err;
        return .{ .allocator = allocator, .status = self.status, .body = try allocator.dupe(u8, self.response) };
    }
};

fn fakeClient(allocator: std.mem.Allocator, fake: *FakeTransport) Client {
    return Client.init(.{
        .allocator = allocator,
        .io = std.testing.io,
        .api_key = "offline",
        .base_url = "offline://anthropic/",
        .transport = fake.transport(),
        .max_response_bytes = fake.limit,
    });
}

test "anthropic injected transport plain completion is schema free and preserves controls and headers" {
    var fake: FakeTransport = .{
        .response =
        \\{"stop_reason":"end_turn","content":[{"type":"text","text":"Hello "},{"type":"thinking","thinking":"private"},{"type":"text","text":"world!"}],"usage":{"input_tokens":2,"output_tokens":3}}
        ,
        .version = "custom-version",
        .beta = "custom-beta",
        .max_tokens = 777,
        .limit = 8192,
    };
    var client = fakeClient(std.testing.allocator, &fake);
    defer client.deinit();
    client.max_tokens = 777;
    const headers = [_]std.http.Header{
        .{ .name = "Anthropic-Version", .value = "custom-version" },
        .{ .name = "anthropic-beta", .value = "custom-beta" },
        .{ .name = "X-Api-Key", .value = "stale-key" },
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    client.sdk.default_headers = &headers;
    var completion = try client.completeText(std.testing.allocator, test_request);
    defer completion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello world!", completion.text);
    try std.testing.expectEqualStrings(fake.response, completion.raw_response);
    try std.testing.expectEqual(@as(u64, 5), completion.usage.total_tokens);
    try std.testing.expectEqual(@intFromPtr(&headers), @intFromPtr(client.sdk.default_headers.ptr));
    try std.testing.expectEqualStrings("stale-key", headers[2].value);
    var request = test_request;
    request.model = "custom-model";
    request.max_tokens = 123;
    fake.model = request.model;
    fake.max_tokens = 123;
    var override = try client.completeText(std.testing.allocator, request);
    defer override.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "anthropic injected transport supplies required headers without system and borrows context" {
    var fake: FakeTransport = .{ .system_count = 0 };
    const request: Client.Request = .{ .model = Client.default_model, .messages = &.{test_request.messages[1]} };
    {
        var client = fakeClient(std.testing.allocator, &fake);
        defer client.deinit();
        client.sdk.default_headers = &.{};
        var completion = try client.completeText(std.testing.allocator, request);
        defer completion.deinit(std.testing.allocator);
    }
    var client = fakeClient(std.testing.allocator, &fake);
    defer client.deinit();
    var completion = try client.completeText(std.testing.allocator, request);
    defer completion.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "anthropic injected transport keeps structured schema and native tools" {
    inline for (.{ types.Mode.json_schema, types.Mode.tool_call, types.Mode.tool_call_required }) |mode| {
        var fake: FakeTransport = .{ .mode = mode, .response = if (mode == .json_schema) test_text_response else test_tool_response };
        var client = fakeClient(std.testing.allocator, &fake);
        defer client.deinit();
        var completion = try client.completeStructured(std.testing.allocator, test_request, test_schema, .{ .mode = mode });
        defer completion.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("{\"age\":42}", completion.text);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expect(std.mem.indexOf(u8, test_schema.schema_json, "\"maximum\":130") != null);
    }
}

test "anthropic injected transport retains response diagnostics and clears them before send errors" {
    inline for (.{
        .{ std.http.Status.too_many_requests, "rate limited", error.ProviderHttpError },
        .{ std.http.Status.ok, "not json", error.InvalidProviderResponse },
        .{ std.http.Status.ok, "{\"content\":[]}", error.MissingOutputText },
        .{ std.http.Status.ok, "{\"error\":{}}", error.ProviderHttpError },
        .{ std.http.Status.ok, "{\"stop_reason\":\"refusal\"}", error.Refusal },
        .{ std.http.Status.ok, "{\"content\":[{\"type\":\"refusal\"}]}", error.Refusal },
        .{ std.http.Status.ok, "{\"stop_reason\":\"max_tokens\"}", error.MaxTokensExceeded },
        .{ std.http.Status.ok, "{\"stop_reason\":\"pause_turn\"}", error.IncompleteResponse },
        .{ std.http.Status.ok, "{\"stop_reason\":\"model_context_window_exceeded\"}", error.IncompleteResponse },
    }) |case| {
        var fake: FakeTransport = .{ .status = case[0], .response = case[1] };
        var client = fakeClient(std.testing.allocator, &fake);
        defer client.deinit();
        try std.testing.expectError(case[2], client.completeText(std.testing.allocator, test_request));
        try std.testing.expectEqual(case[0], client.lastStatus().?);
        try std.testing.expectEqualStrings(case[1], client.lastErrorBody().?);
        try std.testing.expectEqualStrings("anthropic", client.diagnostic().provider);
        fake.failure = error.OfflineTransportFailure;
        try std.testing.expectError(error.OfflineTransportFailure, client.completeText(std.testing.allocator, test_request));
        try std.testing.expect(client.lastStatus() == null);
        try std.testing.expect(client.lastErrorBody() == null);
        fake.failure = null;
        fake.response = test_text_response;
        fake.status = .ok;
        var completion = try client.completeText(std.testing.allocator, test_request);
        defer completion.deinit(std.testing.allocator);
        try std.testing.expect(client.lastErrorBody() == null);
    }
}

test "anthropic injected transport rejects unsupported inputs and enforces response limit" {
    var fake: FakeTransport = .{};
    var client = fakeClient(std.testing.allocator, &fake);
    defer client.deinit();
    var request = test_request;
    request.max_tokens = 0;
    try std.testing.expectError(error.InvalidMaxTokens, client.completeText(std.testing.allocator, request));
    request.messages = &.{.{ .role = .user, .content = "image", .images = &.{.{ .url = "offline://image" }} }};
    request.max_tokens = 1;
    try std.testing.expectError(error.UnsupportedImages, client.completeText(std.testing.allocator, request));
    try std.testing.expectError(error.UnsupportedMode, client.completeStructured(std.testing.allocator, test_request, test_schema, .{ .mode = .json_object }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    fake.limit = 1;
    client.max_response_bytes = 1;
    try std.testing.expectError(error.ResponseTooLarge, client.completeText(std.testing.allocator, test_request));
    try std.testing.expect(client.lastStatus() == null);
    try std.testing.expect(client.lastErrorBody() == null);
}

fn injectedAllocationExercise(allocator: std.mem.Allocator) !void {
    var fake: FakeTransport = .{};
    var client = fakeClient(allocator, &fake);
    defer client.deinit();
    var plain = try client.completeText(allocator, test_request);
    defer plain.deinit(allocator);
    fake.mode = .tool_call_required;
    fake.response = test_tool_response;
    var tool = try client.completeStructured(allocator, test_request, test_schema, .{ .mode = .tool_call_required });
    defer tool.deinit(allocator);
    fake.mode = null;
    fake.status = .bad_request;
    fake.response = "bad request";
    _ = client.completeText(allocator, test_request) catch |err| switch (err) {
        error.ProviderHttpError => return,
        else => return err,
    };
    return error.ExpectedProviderError;
}

test "anthropic injected transport cleans up all allocation failure paths" {
    // Arena growth can resize backing buffers depending on SafeAllocator bucket
    // state left by earlier runs, changing the number of allocation failure points.
    // Reject both resize and remap so growth always takes the allocation fallback.
    // The checker's inner FailingAllocator still fails every allocation in turn.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), injectedAllocationExercise, .{});
}

const OfflineProvider = struct {
    client: Client,
    calls: usize = 0,
    saw_parse_feedback: bool = false,
    saw_validation_feedback: bool = false,

    pub fn completeStructured(self: *@This(), allocator: std.mem.Allocator, request: Client.Request, schema: types.StructuredSchema, comptime options: Options) !types.Completion {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const body = try buildRequest(arena.allocator(), request, schema, options.mode, self.client.max_tokens);
        const remote = if (options.mode == .json_schema) remoteFromBody(body) else body.object.get("tools").?.array.items[0].object.get("input_schema").?;
        try std.testing.expect(remote.object.get("properties").?.object.get("age").?.object.get("maximum") == null);
        try std.testing.expect(std.mem.indexOf(u8, schema.schema_json, "\"maximum\":130") != null);
        self.calls += 1;
        const response = switch (self.calls) {
            1 => "{\"age\":\"not a number\"}",
            2 => "{\"age\":200}",
            else => "{\"age\":42}",
        };
        if (options.mode == .json_schema) {
            const raw = try std.json.Stringify.valueAlloc(allocator, .{ .content = .{.{ .type = "text", .text = response }} }, .{});
            defer allocator.free(raw);
            return self.client.receive(allocator, .ok, raw, options.mode, schema.name);
        }
        var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
        defer parsed.deinit();
        const raw = try std.json.Stringify.valueAlloc(allocator, .{ .content = .{.{ .type = "tool_use", .name = schema.name, .input = parsed.value }} }, .{});
        defer allocator.free(raw);
        return self.client.receive(allocator, .ok, raw, options.mode, schema.name);
    }

    pub fn appendRetry(self: *@This(), allocator: std.mem.Allocator, request: *Client.Request, retry: types.RetryMessage) !void {
        self.saw_parse_feedback = self.saw_parse_feedback or std.mem.indexOf(u8, retry.error_message, "JSON parsing failed") != null;
        self.saw_validation_feedback = self.saw_validation_feedback or std.mem.indexOf(u8, retry.error_message, "failed schema validation") != null;
        try self.client.appendRetry(allocator, request, retry);
    }

    pub fn deinitRequest(self: *@This(), allocator: std.mem.Allocator, request: *Client.Request) void {
        self.client.deinitRequest(allocator, request);
    }
};

test "anthropic schema profile compiles and core retries preserve local constraints" {
    const core = @import("../core/mod.zig");
    const Person = struct {
        age: u8,
        pub const jsonschema = .{ .name = "Person", .fields = .{ .age = .{ .maximum = 130 } } };
    };
    const WithArray = struct { numbers: [2]u8 };
    var profile = try core.schemaAlloc(WithArray, std.testing.allocator, anthropic_schema_options);
    defer profile.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, profile.schema_json, "minimum") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile.schema_json, "minItems") == null);
    try std.testing.expectEqual(jsonschema.DefMode.never, anthropic_schema_options.use_defs);
    inline for (.{ Options{}, Options{ .mode = .tool_call, .schema_options = anthropic_schema_options } }) |options| {
        var provider: OfflineProvider = .{ .client = testClient(std.testing.allocator) };
        defer provider.client.deinit();
        var session = core.session(std.testing.allocator, &provider);
        defer session.deinit();
        const result = try session.create(Person, test_request, options);
        try std.testing.expectEqual(@as(u8, 42), result.age);
        try std.testing.expectEqual(@as(usize, 3), provider.calls);
        try std.testing.expect(provider.saw_parse_feedback);
        try std.testing.expect(provider.saw_validation_feedback);
    }
}
