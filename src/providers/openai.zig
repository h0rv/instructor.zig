const std = @import("std");
const openai = @import("openai");
const types = @import("../core/types.zig");
const Options = @import("../core/options.zig").Options;

pub const api = openai;

pub const Client = struct {
    pub const default_model = "gpt-5.4-mini";
    pub const Api = openai;

    allocator: std.mem.Allocator,
    sdk: openai.Client,
    endpoint: Endpoint = .responses,
    http_referer: ?[]const u8 = null,
    app_name: ?[]const u8 = null,
    last_status: ?std.http.Status = null,
    last_error_body: ?[]u8 = null,

    pub const Endpoint = enum {
        responses,
        chat_completions,
    };

    pub const Error = error{
        ProviderHttpError,
        MissingOutputText,
        InvalidProviderResponse,
        UnsupportedMode,
    };

    pub const Config = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        api_key: []const u8,
        /// Override for OpenAI-compatible endpoints.
        base_url: []const u8 = "https://api.openai.com/v1",
        /// `.chat_completions` works with OpenRouter and many OpenAI-compatible APIs.
        endpoint: Endpoint = .responses,
        /// Optional OpenRouter ranking header.
        http_referer: ?[]const u8 = null,
        /// Optional OpenRouter ranking header.
        app_name: ?[]const u8 = null,
    };

    pub const Request = struct {
        model: []const u8,
        messages: []const Message,
        temperature: ?f64 = null,
        max_output_tokens: ?u32 = null,
        owned_retry_messages: usize = 0,

        pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
            if (self.owned_retry_messages == 0) return;

            const owned_start = self.messages.len - self.owned_retry_messages;
            for (self.messages[owned_start..]) |message| {
                allocator.free(message.content);
            }
            allocator.free(self.messages);
            self.messages = &.{};
            self.owned_retry_messages = 0;
        }
    };

    pub const Message = struct {
        role: Role,
        content: []const u8,
    };

    pub const Role = enum {
        system,
        user,
        assistant,
    };

    pub fn init(config: Config) Client {
        var sdk = openai.Client.init(config.allocator, config.io, config.api_key);
        sdk.withBaseUrl(config.base_url);
        return .{
            .allocator = config.allocator,
            .sdk = sdk,
            .endpoint = config.endpoint,
            .http_referer = config.http_referer,
            .app_name = config.app_name,
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
        return .{
            .provider = "openai",
            .status = self.last_status,
            .body = self.last_error_body,
        };
    }

    pub fn completeStructured(
        self: *Client,
        allocator: std.mem.Allocator,
        request: Request,
        schema: types.StructuredSchema,
        comptime options: Options,
    ) !types.Completion {
        self.clearLastError();
        if (options.mode != .json_schema) return Error.UnsupportedMode;

        var default_headers_buf: [2]std.http.Header = undefined;
        var default_headers_len: usize = 0;
        if (self.http_referer) |http_referer| {
            default_headers_buf[default_headers_len] = .{ .name = "HTTP-Referer", .value = http_referer };
            default_headers_len += 1;
        }
        if (self.app_name) |app_name| {
            default_headers_buf[default_headers_len] = .{ .name = "X-Title", .value = app_name };
            default_headers_len += 1;
        }
        const previous_headers = self.sdk.default_headers;
        self.sdk.default_headers = default_headers_buf[0..default_headers_len];
        defer self.sdk.default_headers = previous_headers;

        var raw = switch (self.endpoint) {
            .responses => try postResponses(self, allocator, request, schema),
            .chat_completions => try postChatCompletions(self, allocator, request, schema),
        };
        defer raw.deinit();

        if (raw.status.class() != .success or try hasProviderError(allocator, raw.body)) {
            self.last_status = raw.status;
            self.last_error_body = try self.allocator.dupe(u8, raw.body);
            return Error.ProviderHttpError;
        }

        const raw_response = try allocator.dupe(u8, raw.body);
        errdefer allocator.free(raw_response);

        const text = extractOutputText(allocator, raw_response) catch |err| {
            self.last_status = raw.status;
            self.last_error_body = try self.allocator.dupe(u8, raw_response);
            return err;
        };
        errdefer allocator.free(text);

        return .{
            .text = text,
            .raw_response = raw_response,
            .usage = extractUsage(allocator, raw_response) catch .{},
        };
    }

    pub fn appendRetry(
        self: *Client,
        allocator: std.mem.Allocator,
        request: *Request,
        retry: types.RetryMessage,
    ) !void {
        _ = self;

        const failed_response = try allocator.dupe(u8, retry.failed_response);
        errdefer allocator.free(failed_response);

        const error_message = try allocator.dupe(u8, retry.error_message);
        errdefer allocator.free(error_message);

        const old_messages = request.messages;
        const old_owned_count = request.owned_retry_messages;
        const old_slice_owned = old_owned_count > 0;

        const new_messages = try allocator.alloc(Message, old_messages.len + 2);
        errdefer allocator.free(new_messages);

        @memcpy(new_messages[0..old_messages.len], old_messages);
        new_messages[old_messages.len] = .{
            .role = .assistant,
            .content = failed_response,
        };
        new_messages[old_messages.len + 1] = .{
            .role = .user,
            .content = error_message,
        };

        if (old_slice_owned) allocator.free(old_messages);

        request.messages = new_messages;
        request.owned_retry_messages = old_owned_count + 2;
    }

    pub fn deinitRequest(
        self: *Client,
        allocator: std.mem.Allocator,
        request: *Request,
    ) void {
        _ = self;
        request.deinit(allocator);
    }
};

fn postResponses(
    client: *Client,
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
) !openai.RawResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed_schema = try std.json.parseFromSlice(std.json.Value, arena_allocator, schema.schema_json, .{});
    defer parsed_schema.deinit();

    const body = try buildResponsesRequest(arena_allocator, request, schema, parsed_schema.value);
    return openai.postJsonRaw(&client.sdk, "/responses", body);
}

fn postChatCompletions(
    client: *Client,
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
) !openai.RawResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed_schema = try std.json.parseFromSlice(std.json.Value, arena_allocator, schema.schema_json, .{});
    defer parsed_schema.deinit();

    const body = try buildChatCompletionsRequest(arena_allocator, request, schema, parsed_schema.value);
    return openai.postJsonRaw(&client.sdk, "/chat/completions", body);
}

fn buildResponsesRequest(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !openai.CreateResponse {
    return .{
        .model = request.model,
        .input = try messagesValue(allocator, request.messages),
        .text = .{ .format = try responsesFormatValue(allocator, schema, schema_value) },
        .temperature = optionalFloat(request.temperature),
        .max_output_tokens = optionalU32(request.max_output_tokens),
    };
}

fn buildChatCompletionsRequest(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !openai.CreateChatCompletionRequest {
    return .{
        .model = request.model,
        .messages = try messagesSlice(allocator, request.messages),
        .response_format = try chatResponseFormatValue(allocator, schema, schema_value),
        .temperature = optionalFloat(request.temperature),
        .max_tokens = if (request.max_output_tokens) |value| @intCast(value) else null,
    };
}

fn hasProviderError(allocator: std.mem.Allocator, raw_response: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_response, .{});
    defer parsed.deinit();

    return parsed.value == .object and parsed.value.object.get("error") != null;
}

fn extractOutputText(allocator: std.mem.Allocator, raw_response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_response, .{});
    defer parsed.deinit();

    const text = findOutputText(parsed.value) orelse return Client.Error.MissingOutputText;
    return allocator.dupe(u8, text);
}

fn extractUsage(allocator: std.mem.Allocator, raw_response: []const u8) !types.Usage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_response, .{});
    defer parsed.deinit();

    return findUsage(parsed.value) orelse .{};
}

fn findOutputText(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (object.get("output_text")) |output_text| {
                if (output_text == .string) return output_text.string;
            }

            if (object.get("output")) |output| {
                if (findTextInArray(output)) |text| return text;
            }

            if (object.get("choices")) |choices| {
                if (findChatChoiceText(choices)) |text| return text;
            }
        },
        else => {},
    }
    return null;
}

fn findTextInArray(value: std.json.Value) ?[]const u8 {
    if (value != .array) return null;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const item_object = item.object;

        if (item_object.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const part_object = part.object;
                    if (part_object.get("text")) |text| {
                        if (text == .string) return text.string;
                    }
                }
            }
        }
    }
    return null;
}

fn findChatChoiceText(value: std.json.Value) ?[]const u8 {
    if (value != .array or value.array.items.len == 0) return null;
    const choice = value.array.items[0];
    if (choice != .object) return null;
    const message = choice.object.get("message") orelse return null;
    if (message != .object) return null;
    const content = message.object.get("content") orelse return null;
    switch (content) {
        .string => |text| return text,
        .array => |parts| {
            for (parts.items) |part| {
                if (part != .object) continue;
                const text = part.object.get("text") orelse continue;
                if (text == .string) return text.string;
            }
        },
        else => {},
    }
    return null;
}

fn findUsage(value: std.json.Value) ?types.Usage {
    if (value != .object) return null;
    const usage_value = value.object.get("usage") orelse return null;
    if (usage_value != .object) return null;
    const usage = usage_value.object;

    return .{
        .input_tokens = getU64(usage.get("input_tokens")) orelse getU64(usage.get("prompt_tokens")) orelse 0,
        .output_tokens = getU64(usage.get("output_tokens")) orelse getU64(usage.get("completion_tokens")) orelse 0,
        .total_tokens = getU64(usage.get("total_tokens")) orelse 0,
    };
}

fn getU64(value: ?std.json.Value) ?u64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .float => |float| if (float >= 0) @intFromFloat(float) else null,
        else => null,
    };
}

fn messagesValue(allocator: std.mem.Allocator, messages: []const Client.Message) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (messages) |message| {
        try array.append(try messageValue(allocator, message));
    }
    return .{ .array = array };
}

fn messagesSlice(allocator: std.mem.Allocator, messages: []const Client.Message) ![]const openai.ChatCompletionRequestMessage {
    const result = try allocator.alloc(openai.ChatCompletionRequestMessage, messages.len);
    for (messages, result) |message, *out| {
        out.* = .{
            .role = roleString(message.role),
            .content = .{ .string = message.content },
        };
    }
    return result;
}

fn messageValue(allocator: std.mem.Allocator, message: Client.Message) !std.json.Value {
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "role", .{ .string = roleString(message.role) });
    try object.put(allocator, "content", .{ .string = message.content });
    return .{ .object = object };
}

fn responsesFormatValue(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !std.json.Value {
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "type", .{ .string = "json_schema" });
    try object.put(allocator, "name", .{ .string = schema.name });
    if (schema.description) |description| {
        try object.put(allocator, "description", .{ .string = description });
    }
    try object.put(allocator, "strict", .{ .bool = schema.strict });
    try object.put(allocator, "schema", schema_value);
    return .{ .object = object };
}

fn chatResponseFormatValue(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !std.json.Value {
    var json_schema = std.json.ObjectMap.empty;
    try json_schema.put(allocator, "name", .{ .string = schema.name });
    if (schema.description) |description| {
        try json_schema.put(allocator, "description", .{ .string = description });
    }
    try json_schema.put(allocator, "strict", .{ .bool = schema.strict });
    try json_schema.put(allocator, "schema", schema_value);

    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "type", .{ .string = "json_schema" });
    try object.put(allocator, "json_schema", .{ .object = json_schema });
    return .{ .object = object };
}

fn optionalFloat(value: ?f64) ?std.json.Value {
    return if (value) |v| .{ .float = v } else null;
}

fn optionalU32(value: ?u32) ?std.json.Value {
    return if (value) |v| .{ .integer = @intCast(v) } else null;
}

fn roleString(role: Client.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
    };
}

test "build responses request writes raw schema" {
    const schema: types.StructuredSchema = .{
        .name = "Person",
        .description = "Extract person.",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_schema = try std.json.parseFromSlice(std.json.Value, arena.allocator(), schema.schema_json, .{});
    defer parsed_schema.deinit();

    const body = try buildResponsesRequest(arena.allocator(), request, schema, parsed_schema.value);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"Person\"") != null);
}

test "build chat completions request uses chat max token field" {
    const schema: types.StructuredSchema = .{
        .name = "Person",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
        .max_output_tokens = 128,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_schema = try std.json.parseFromSlice(std.json.Value, arena.allocator(), schema.schema_json, .{});
    defer parsed_schema.deinit();

    const body = try buildChatCompletionsRequest(arena.allocator(), request, schema, parsed_schema.value);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_tokens\":128") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_output_tokens\"") == null);
}

test "extract output text from responses shape" {
    const raw =
        \\{
        \\  "output": [{"content": [{"type": "output_text", "text": "{\"name\":\"Ada\"}"}]}],
        \\  "usage": {"input_tokens": 1, "output_tokens": 2, "total_tokens": 3}
        \\}
    ;

    const text = try extractOutputText(std.testing.allocator, raw);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\"}", text);

    const usage = try extractUsage(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(u64, 3), usage.total_tokens);
}
