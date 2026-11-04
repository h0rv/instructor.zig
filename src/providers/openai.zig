const std = @import("std");
const openai = @import("openai");
const types = @import("../core/types.zig");
const Options = @import("../core/options.zig").Options;
const http = @import("../transport.zig");
const request_options = @import("../request_options.zig");
const decisions = @import("../decisions.zig");
pub const QueryParam = request_options.QueryParam;

pub const api = openai;

pub const Client = struct {
    pub const default_model = "gpt-5.4-mini";
    pub const Api = openai;

    allocator: std.mem.Allocator,
    sdk: openai.Client,
    endpoint: Endpoint = .responses,
    http_referer: ?[]const u8 = null,
    app_name: ?[]const u8 = null,
    transport: ?http.Transport = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
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
        Refusal,
        IncompleteResponse,
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
        transport: ?http.Transport = null,
        max_response_bytes: usize = 8 * 1024 * 1024,
    };

    pub const Request = struct {
        model: []const u8,
        messages: []const Message,
        temperature: ?f64 = null,
        max_output_tokens: ?u32 = null,
        extra_body: ?std.json.Value = null,
        extra_headers: []const std.http.Header = &.{},
        extra_query: []const QueryParam = &.{},
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
        images: []const Image = &.{},
    };

    pub const Image = struct {
        url: []const u8,
        detail: ?[]const u8 = null,
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
        if (!modeSupported(self.endpoint, options.mode)) return Error.UnsupportedMode;

        var raw = switch (self.endpoint) {
            .responses => try postResponses(self, allocator, request, schema, options.mode),
            .chat_completions => try postChatCompletions(self, allocator, request, schema, options.mode),
        };
        defer raw.deinit();
        return self.decodeCompletion(allocator, raw, false);
    }

    /// Ordinary completion without a schema, response format, or tools.
    pub fn completeText(self: *Client, allocator: std.mem.Allocator, request: Request) !types.Completion {
        self.clearLastError();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var raw = switch (self.endpoint) {
            .responses => try dispatch(self, allocator, "/responses", try responsesBase(arena.allocator(), request), request, false),
            .chat_completions => try dispatch(self, allocator, "/chat/completions", try chatBase(arena.allocator(), request), request, false),
        };
        defer raw.deinit();
        return self.decodeCompletion(allocator, raw, true);
    }

    /// Native Decisions request. Questions and input are borrowed only during this call.
    pub fn createDecision(self: *Client, allocator: std.mem.Allocator, request: decisions.CreateParams) !decisions.Response {
        self.clearLastError();
        const model = request.model orelse return error.MissingModel;
        if (model.len == 0) return error.MissingModel;
        if (request.questions.len == 0 or request.questions.len > 400) return error.InvalidDecisionQuestions;

        const body: openai.DecisionRequest = .{
            .model = model,
            .input = .{ .string = request.input },
            .questions = request.questions,
        };
        var raw = try dispatch(self, allocator, "/decisions", body, request, false);
        defer raw.deinit();
        return self.decodeDecision(allocator, raw) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.last_status = raw.status;
            self.last_error_body = try self.allocator.dupe(u8, raw.body);
            return err;
        };
    }

    fn decodeDecision(self: *Client, allocator: std.mem.Allocator, raw: openai.RawResponse) !decisions.Response {
        _ = self;
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        if (raw.status.class() != .success or try hasProviderError(owned, raw.body)) return Error.ProviderHttpError;
        const raw_response = try owned.dupe(u8, raw.body);
        const value = try std.json.parseFromSliceLeaky(openai.DecisionResponse, owned, raw_response, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        });
        return .{
            .arena = arena,
            .value = value,
            .status = raw.status,
            .raw_response = raw_response,
            .usage = try extractUsage(owned, raw_response),
            .model = value.model,
        };
    }

    fn decodeCompletion(self: *Client, allocator: std.mem.Allocator, raw: openai.RawResponse, ordinary: bool) !types.Completion {
        return self.decodeCompletionInner(allocator, raw, ordinary) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.last_status = raw.status;
            self.last_error_body = try self.allocator.dupe(u8, raw.body);
            return err;
        };
    }

    fn decodeCompletionInner(self: *Client, allocator: std.mem.Allocator, raw: openai.RawResponse, ordinary: bool) !types.Completion {
        if (raw.status.class() != .success or try hasProviderError(allocator, raw.body)) {
            return Error.ProviderHttpError;
        }

        const raw_response = try allocator.dupe(u8, raw.body);
        errdefer allocator.free(raw_response);

        const text = if (ordinary)
            try extractOrdinaryText(allocator, raw_response, self.endpoint)
        else
            try extractOutputText(allocator, raw_response);
        errdefer allocator.free(text);

        return .{
            .text = text,
            .raw_response = raw_response,
            .usage = try extractUsage(allocator, raw_response),
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

fn modeSupported(endpoint: Client.Endpoint, mode: types.Mode) bool {
    return switch (endpoint) {
        .responses => switch (mode) {
            .json_schema, .json_object, .responses_tool_call, .responses_tool_call_required => true,
            .tool_call, .tool_call_required => false,
        },
        .chat_completions => switch (mode) {
            .json_schema, .json_object, .tool_call, .tool_call_required => true,
            .responses_tool_call, .responses_tool_call_required => false,
        },
    };
}

fn postResponses(
    client: *Client,
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    mode: types.Mode,
) !openai.RawResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed_schema = try parseSchemaValue(arena_allocator, schema.schema_json);
    defer parsed_schema.deinit();

    const body = try buildResponsesRequest(arena_allocator, request, schema, parsed_schema.value, mode);
    return dispatch(client, allocator, "/responses", body, request, true);
}

fn postChatCompletions(
    client: *Client,
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    mode: types.Mode,
) !openai.RawResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed_schema = try parseSchemaValue(arena_allocator, schema.schema_json);
    defer parsed_schema.deinit();

    const body = try buildChatCompletionsRequest(arena_allocator, request, schema, parsed_schema.value, mode);
    return dispatch(client, allocator, "/chat/completions", body, request, true);
}

/// Preserve the SDK dispatch (including observers) for existing low-level callers.
fn dispatch(client: *Client, allocator: std.mem.Allocator, path: []const u8, body: anytype, request: anytype, structured: bool) !openai.RawResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const api_kind: request_options.Api = if (std.mem.eql(u8, path, "/decisions")) .decisions else if (client.endpoint == .responses) .responses else .chat_completions;
    const merged = try request_options.mergePayload(scratch, body, request.extra_body, api_kind, structured);
    const payload = try std.json.Stringify.valueAlloc(scratch, merged, .{});
    var defaults: std.ArrayList(std.http.Header) = .empty;
    try defaults.appendSlice(scratch, client.sdk.default_headers);
    if (client.http_referer) |value| try defaults.append(scratch, .{ .name = "HTTP-Referer", .value = value });
    if (client.app_name) |value| try defaults.append(scratch, .{ .name = "X-Title", .value = value });
    // The SDK raw helper does not add Bearer authentication itself.
    if (client.sdk.api_key.len != 0) try defaults.append(scratch, .{ .name = "Authorization", .value = try scratch.print("Bearer {s}", .{client.sdk.api_key}) });
    try defaults.appendSlice(scratch, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    });
    if (client.sdk.organization) |value| try defaults.append(scratch, .{ .name = "OpenAI-Organization", .value = value });
    if (client.sdk.project) |value| try defaults.append(scratch, .{ .name = "OpenAI-Project", .value = value });
    const headers = try request_options.mergeHeaders(scratch, defaults.items, request.extra_headers);
    const endpoint = try request_options.endpointUrl(scratch, client.sdk.base_url, path);
    const url = try request_options.appendQuery(scratch, endpoint, request.extra_query);
    const transport = client.transport orelse {
        // Pass final headers as SDK overrides so its automatic content type,
        // accept and organization headers cannot create duplicate wire members.
        const previous_headers = client.sdk.default_headers;
        client.sdk.default_headers = &.{};
        defer client.sdk.default_headers = previous_headers;
        return openai.requestRawWithExtraHeaders(&client.sdk, .POST, url, payload, headers);
    };
    const response = try transport.send(client.sdk.io, allocator, .{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = payload,
        .max_response_bytes = client.max_response_bytes,
    });
    // Transfer the owned body, without touching the borrowed transport context.
    return .{ .allocator = response.allocator, .status = response.status, .body = response.body };
}

fn responsesBase(allocator: std.mem.Allocator, request: Client.Request) !openai.CreateResponse {
    return .{
        .model = request.model,
        .input = .{ .input_item_list = try inputItems(allocator, request.messages) },
        .temperature = request.temperature,
        .max_output_tokens = if (request.max_output_tokens) |value| @as(?i64, @intCast(value)) else null,
    };
}

fn chatBase(allocator: std.mem.Allocator, request: Client.Request) !openai.CreateChatCompletionRequest {
    return .{
        .model = request.model,
        .messages = try messagesSlice(allocator, request.messages),
        .temperature = request.temperature,
        .max_tokens = if (request.max_output_tokens) |value| @intCast(value) else null,
    };
}

fn parseSchemaValue(allocator: std.mem.Allocator, schema_json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{
        .duplicate_field_behavior = .use_last,
    });
}

fn buildResponsesRequest(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
    mode: types.Mode,
) !openai.CreateResponse {
    var body = try responsesBase(allocator, request);

    switch (mode) {
        .json_schema => body.text = .{ .format = try responsesFormat(allocator, schema, schema_value) },
        .json_object => body.text = .{ .format = .{ .json_object = .{ .type = "json_object" } } },
        .responses_tool_call, .responses_tool_call_required => {
            body.tools = try responsesToolSlice(allocator, schema, schema_value);
            if (mode == .responses_tool_call_required) {
                body.tool_choice = .{ .tool_choice_function = .{ .type = "function", .name = schema.name } };
            }
        },
        .tool_call, .tool_call_required => unreachable,
    }

    return body;
}

fn buildChatCompletionsRequest(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
    mode: types.Mode,
) !openai.CreateChatCompletionRequest {
    var body = try chatBase(allocator, request);

    switch (mode) {
        .json_schema => body.response_format = try chatResponseFormat(allocator, schema, schema_value),
        .json_object => body.response_format = .{ .json_object = .{ .type = "json_object" } },
        .tool_call, .tool_call_required => {
            body.tools = try chatToolSlice(allocator, schema, schema_value);
            if (mode == .tool_call_required) {
                body.tool_choice = .{ .chat_completion_named_tool_choice = .{
                    .type = "function",
                    .function = .{ .name = schema.name },
                } };
            }
        },
        .responses_tool_call, .responses_tool_call_required => unreachable,
    }

    return body;
}

fn hasProviderError(allocator: std.mem.Allocator, raw_response: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_response, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const provider_error = parsed.value.object.get("error") orelse return false;
    return provider_error != .null;
}

fn extractOutputText(allocator: std.mem.Allocator, raw_response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_response, .{});
    defer parsed.deinit();

    const text = findOutputText(parsed.value) orelse return Client.Error.MissingOutputText;
    return allocator.dupe(u8, text);
}

fn isString(value: ?std.json.Value, expected: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}

fn checkTextStatus(value: std.json.Value) !void {
    if (value != .object) return Client.Error.InvalidProviderResponse;
    if (value.object.get("refusal")) |refusal| {
        if (refusal != .null) return Client.Error.Refusal;
    }
    if (isString(value.object.get("type"), "refusal")) return Client.Error.Refusal;
    if (value.object.get("status")) |status| {
        if (!isString(status, "completed")) return Client.Error.IncompleteResponse;
    }
    if (value.object.get("incomplete_details")) |details| {
        if (details != .null) return Client.Error.IncompleteResponse;
    }
}

/// Unlike extraction, ordinary text never falls back to function arguments.
fn extractOrdinaryText(allocator: std.mem.Allocator, raw_response: []const u8, endpoint: Client.Endpoint) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_response, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try checkTextStatus(root);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var found = false;
    switch (endpoint) {
        .responses => {
            if (root.object.get("output")) |output| {
                if (output != .array) return Client.Error.InvalidProviderResponse;
                for (output.array.items) |item| {
                    try checkTextStatus(item);
                    // Reasoning and tool items are not ordinary output text.
                    if (item.object.get("type")) |kind| {
                        if (!isString(kind, "message")) continue;
                    }
                    if (item.object.get("content")) |content| {
                        try appendTextContent(allocator, &text, &found, content);
                    }
                }
            }
            if (!found) {
                if (root.object.get("output_text")) |output_text| {
                    if (output_text != .string) return Client.Error.InvalidProviderResponse;
                    try text.appendSlice(allocator, output_text.string);
                    found = true;
                }
            }
        },
        .chat_completions => {
            const choices = root.object.get("choices") orelse return Client.Error.MissingOutputText;
            if (choices != .array or choices.array.items.len == 0) return Client.Error.MissingOutputText;
            const choice = choices.array.items[0];
            try checkTextStatus(choice);
            if (choice.object.get("finish_reason")) |reason| {
                if (isString(reason, "content_filter")) return Client.Error.Refusal;
                if (!isString(reason, "stop")) return Client.Error.IncompleteResponse;
            }
            if (choice.object.get("message")) |message| {
                try checkTextStatus(message);
                if (message.object.get("content")) |content| {
                    try appendTextContent(allocator, &text, &found, content);
                }
            } else if (choice.object.get("text")) |content| {
                try appendTextContent(allocator, &text, &found, content);
            }
        },
    }
    if (!found) return Client.Error.MissingOutputText;
    return text.toOwnedSlice(allocator);
}

fn appendTextContent(allocator: std.mem.Allocator, text: *std.ArrayList(u8), found: *bool, content: std.json.Value) !void {
    switch (content) {
        .string => |value| {
            try text.appendSlice(allocator, value);
            found.* = true;
        },
        .array => |parts| for (parts.items) |part| {
            try checkTextStatus(part);
            if (part.object.get("type")) |kind| {
                if (!isString(kind, "text") and !isString(kind, "output_text")) continue;
            }
            if (part.object.get("text")) |value| {
                if (value != .string) return Client.Error.InvalidProviderResponse;
                try text.appendSlice(allocator, value.string);
                found.* = true;
            }
        },
        .null => {},
        else => return Client.Error.InvalidProviderResponse,
    }
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
                if (findChatChoiceToolArguments(choices)) |text| return text;
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

        if (item_object.get("arguments")) |arguments| {
            if (arguments == .string) return arguments.string;
        }

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

fn findChatChoiceToolArguments(value: std.json.Value) ?[]const u8 {
    if (value != .array or value.array.items.len == 0) return null;
    const choice = value.array.items[0];
    if (choice != .object) return null;
    const message = choice.object.get("message") orelse return null;
    if (message != .object) return null;
    const tool_calls = message.object.get("tool_calls") orelse return null;
    if (tool_calls != .array or tool_calls.array.items.len == 0) return null;
    const tool_call = tool_calls.array.items[0];
    if (tool_call != .object) return null;
    const function = tool_call.object.get("function") orelse return null;
    if (function != .object) return null;
    const arguments = function.object.get("arguments") orelse return null;
    if (arguments == .string) return arguments.string;
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
        .float => |float| if (std.math.isFinite(float) and float >= 0 and float < 0x1p64 and @trunc(float) == float) @intFromFloat(float) else null,
        else => null,
    };
}

test "usage token counts reject fractional nonfinite and overflowing numbers" {
    try std.testing.expectEqual(@as(?u64, 42), getU64(.{ .float = 42.0 }));
    try std.testing.expectEqual(@as(?u64, null), getU64(.{ .float = 1.5 }));
    try std.testing.expectEqual(@as(?u64, null), getU64(.{ .float = -1.0 }));
    try std.testing.expectEqual(@as(?u64, null), getU64(.{ .float = 0x1p64 }));
    try std.testing.expectEqual(@as(?u64, null), getU64(.{ .float = std.math.inf(f64) }));
    try std.testing.expectEqual(@as(?u64, null), getU64(.{ .float = std.math.nan(f64) }));
}

fn inputItems(allocator: std.mem.Allocator, messages: []const Client.Message) ![]const openai.InputItem {
    const result = try allocator.alloc(openai.InputItem, messages.len);
    for (messages, result) |message, *out| {
        out.* = .{ .easy_input_message = .{
            .role = roleString(message.role),
            .content = if (message.images.len == 0)
                .{ .text = message.content }
            else
                .{ .input_message_content_list = try responsesContentParts(allocator, message) },
        } };
    }
    return result;
}

fn messagesSlice(allocator: std.mem.Allocator, messages: []const Client.Message) ![]const openai.ChatCompletionRequestMessage {
    const result = try allocator.alloc(openai.ChatCompletionRequestMessage, messages.len);
    for (messages, result) |message, *out| {
        out.* = switch (message.role) {
            .system => .{
                .system = .{
                    .role = "system",
                    .content = if (message.images.len == 0)
                        .{ .text = message.content }
                    else
                        // Compatible endpoints may allow images in system messages,
                        // which the SDK's text-only system content cannot represent.
                        .{ .raw = try rawChatContentParts(allocator, message) },
                },
            },
            .user => .{ .user = .{
                .role = "user",
                .content = if (message.images.len == 0)
                    .{ .text = message.content }
                else
                    .{ .array_of_content_parts = try chatContentParts(allocator, message) },
            } },
            .assistant => .{
                .assistant = .{
                    .role = "assistant",
                    // The generated assistant content type is std.json.Value.
                    .content = if (message.images.len == 0)
                        .{ .string = message.content }
                    else
                        try rawChatContentParts(allocator, message),
                },
            },
        };
    }
    return result;
}

fn responsesContentParts(allocator: std.mem.Allocator, message: Client.Message) ![]const openai.InputContent {
    const text_count: usize = if (message.content.len == 0) 0 else 1;
    const result = try allocator.alloc(openai.InputContent, text_count + message.images.len);
    var index: usize = 0;

    if (message.content.len != 0) {
        result[index] = .{ .input_text = .{ .type = "input_text", .text = message.content } };
        index += 1;
    }

    for (message.images) |image| {
        result[index] = .{ .input_image = .{
            .type = "input_image",
            .image_url = image.url,
            .detail = image.detail orelse "auto",
        } };
        index += 1;
    }

    return result;
}

fn chatContentParts(allocator: std.mem.Allocator, message: Client.Message) ![]const openai.ChatCompletionRequestUserMessageContentPart {
    const text_count: usize = if (message.content.len == 0) 0 else 1;
    const parts = try allocator.alloc(openai.ChatCompletionRequestUserMessageContentPart, text_count + message.images.len);
    if (text_count != 0) {
        parts[0] = .{ .chat_completion_request_message_content_part_text = .{
            .type = "text",
            .text = message.content,
        } };
    }
    for (message.images, parts[text_count..]) |image, *part| {
        part.* = .{ .chat_completion_request_message_content_part_image = .{
            .type = "image_url",
            .image_url = .{ .url = image.url, .detail = image.detail },
        } };
    }
    return parts;
}

fn rawChatContentParts(allocator: std.mem.Allocator, message: Client.Message) !std.json.Value {
    var parts = std.json.Array.init(allocator);

    if (message.content.len != 0) {
        var text = std.json.ObjectMap.empty;
        try text.put(allocator, "type", .{ .string = "text" });
        try text.put(allocator, "text", .{ .string = message.content });
        try parts.append(.{ .object = text });
    }

    for (message.images) |image| {
        var image_url = std.json.ObjectMap.empty;
        try image_url.put(allocator, "url", .{ .string = image.url });
        if (image.detail) |detail| {
            try image_url.put(allocator, "detail", .{ .string = detail });
        }

        var part = std.json.ObjectMap.empty;
        try part.put(allocator, "type", .{ .string = "image_url" });
        try part.put(allocator, "image_url", .{ .object = image_url });
        try parts.append(.{ .object = part });
    }

    return .{ .array = parts };
}

fn responsesFormat(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !openai.TextResponseFormatConfiguration {
    return .{ .json_schema = .{
        .type = "json_schema",
        .name = schema.name,
        .description = schema.description,
        .strict = @as(?bool, schema.strict),
        .schema = try responseSchemaValue(allocator, schema_value),
    } };
}

fn chatResponseFormat(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !openai.CreateChatCompletionRequestResponseFormat {
    return .{ .json_schema = .{
        .type = "json_schema",
        .json_schema = .{
            .name = schema.name,
            .description = schema.description,
            .strict = @as(?bool, schema.strict),
            .schema = try responseSchemaValue(allocator, schema_value),
        },
    } };
}

fn chatToolSlice(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) ![]const openai.CreateChatCompletionRequestToolsItem {
    const tools = try allocator.alloc(openai.CreateChatCompletionRequestToolsItem, 1);
    tools[0] = .{ .chat_completion_tool = .{
        .type = "function",
        .function = try functionObject(allocator, schema, schema_value),
    } };
    return tools;
}

fn responsesToolSlice(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !openai.ToolsArray {
    const tools = try allocator.alloc(openai.Tool, 1);
    tools[0] = .{ .function = .{
        .type = "function",
        .name = schema.name,
        .description = schema.description,
        .parameters = try functionParametersValue(allocator, schema_value),
        .strict = schema.strict,
    } };
    return tools;
}

fn functionObject(
    allocator: std.mem.Allocator,
    schema: types.StructuredSchema,
    schema_value: std.json.Value,
) !openai.FunctionObject {
    return .{
        .name = schema.name,
        .description = schema.description,
        .parameters = try functionParametersValue(allocator, schema_value),
        .strict = schema.strict,
    };
}

fn responseSchemaValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !openai.ResponseFormatJsonSchemaSchema {
    return openai.ResponseFormatJsonSchemaSchema.jsonParseFromValue(allocator, value, .{});
}

fn functionParametersValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !openai.FunctionParameters {
    return openai.FunctionParameters.jsonParseFromValue(allocator, value, .{});
}

fn roleString(role: Client.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
    };
}

test "build responses request supports multimodal input" {
    const schema: types.StructuredSchema = .{
        .name = "ImageSummary",
        .schema_json = "{\"type\":\"object\"}",
    };
    const images = [_]Client.Image{.{ .url = "https://example.com/image.jpg", .detail = "low" }};
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Describe this image.", .images = &images }},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_schema = try parseSchemaValue(arena.allocator(), schema.schema_json);
    defer parsed_schema.deinit();

    const body = try buildResponsesRequest(arena.allocator(), request, schema, parsed_schema.value, .json_schema);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"input_image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "https://example.com/image.jpg") != null);
}

test "chat messages preserve roles and typed multimodal content" {
    const images = [_]Client.Image{
        .{ .url = "https://example.com/image.jpg", .detail = "low" },
        .{ .url = "data:image/png;base64,AAAA" },
    };
    const messages = [_]Client.Message{
        .{ .role = .system, .content = "Extract the image details." },
        .{ .role = .user, .content = "Describe these images.", .images = &images },
        .{ .role = .assistant, .content = "{\"summary\":\"\"}" },
        .{ .role = .user, .content = "Fix the empty summary." },
        .{ .role = .user, .content = "", .images = &images },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const converted = try messagesSlice(arena.allocator(), &messages);
    try std.testing.expect(converted[0] == .system);
    try std.testing.expect(converted[0].system.content == .text);
    try std.testing.expect(converted[1] == .user);
    const parts = converted[1].user.content.array_of_content_parts;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expect(parts[0] == .chat_completion_request_message_content_part_text);
    try std.testing.expect(parts[1] == .chat_completion_request_message_content_part_image);
    try std.testing.expect(parts[2] == .chat_completion_request_message_content_part_image);
    try std.testing.expect(converted[2] == .assistant);
    try std.testing.expect(converted[3].user.content == .text);
    try std.testing.expectEqual(@as(usize, 2), converted[4].user.content.array_of_content_parts.len);

    const payload = try std.json.Stringify.valueAlloc(arena.allocator(), converted, .{ .emit_null_optional_fields = false });
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"system\",\"content\":\"Extract the image details.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"image_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"url\":\"https://example.com/image.jpg\",\"detail\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"url\":\"data:image/png;base64,AAAA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "array_of_content_parts") == null);
}

test "chat compatible endpoint content preserves system and assistant images" {
    const images = [_]Client.Image{.{ .url = "https://example.com/image.jpg", .detail = "high" }};
    const messages = [_]Client.Message{
        .{ .role = .system, .content = "", .images = &images },
        .{ .role = .assistant, .content = "An image.", .images = &images },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const converted = try messagesSlice(arena.allocator(), &messages);
    try std.testing.expect(converted[0] == .system);
    try std.testing.expect(converted[0].system.content == .raw);
    try std.testing.expect(converted[1] == .assistant);
    const payload = try std.json.Stringify.valueAlloc(arena.allocator(), converted, .{ .emit_null_optional_fields = false });
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{});
    defer parsed.deinit();
    const system_parts = parsed.value.array.items[0].object.get("content").?.array.items;
    const assistant_parts = parsed.value.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), system_parts.len);
    try std.testing.expectEqualStrings("image_url", system_parts[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), assistant_parts.len);
    try std.testing.expectEqualStrings("An image.", assistant_parts[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("high", assistant_parts[1].object.get("image_url").?.object.get("detail").?.string);
}

test "build requests supports every endpoint mode with typed formats and tools" {
    const schema: types.StructuredSchema = .{
        .name = "Person",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Ada is 42." }},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed_schema = try parseSchemaValue(allocator, schema.schema_json);
    defer parsed_schema.deinit();
    inline for (.{ types.Mode.json_schema, .json_object, .tool_call, .tool_call_required, .responses_tool_call, .responses_tool_call_required }) |mode| {
        if (modeSupported(.responses, mode)) {
            const body = try buildResponsesRequest(allocator, request, schema, parsed_schema.value, mode);
            switch (mode) {
                .json_schema => try std.testing.expect(body.text.?.format.? == .json_schema),
                .json_object => try std.testing.expect(body.text.?.format.? == .json_object),
                .responses_tool_call, .responses_tool_call_required => {
                    try std.testing.expect(body.tools.?[0] == .function);
                    try std.testing.expectEqual(mode == .responses_tool_call_required, body.tool_choice != null);
                },
                else => unreachable,
            }
            _ = try std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
        }
        if (modeSupported(.chat_completions, mode)) {
            const body = try buildChatCompletionsRequest(allocator, request, schema, parsed_schema.value, mode);
            switch (mode) {
                .json_schema => try std.testing.expect(body.response_format.? == .json_schema),
                .json_object => try std.testing.expect(body.response_format.? == .json_object),
                .tool_call, .tool_call_required => {
                    try std.testing.expect(body.tools.?[0] == .chat_completion_tool);
                    try std.testing.expectEqual(mode == .tool_call_required, body.tool_choice != null);
                },
                else => unreachable,
            }
            _ = try std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
        }
    }
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

    const body = try buildResponsesRequest(arena.allocator(), request, schema, parsed_schema.value, .json_schema);
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

    const body = try buildChatCompletionsRequest(arena.allocator(), request, schema, parsed_schema.value, .json_schema);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_tokens\":128") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_output_tokens\"") == null);
}

test "build chat completions json object request" {
    const schema: types.StructuredSchema = .{
        .name = "Person",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_schema = try parseSchemaValue(arena.allocator(), schema.schema_json);
    defer parsed_schema.deinit();

    const body = try buildChatCompletionsRequest(arena.allocator(), request, schema, parsed_schema.value, .json_object);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"response_format\":{\"type\":\"json_object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"json_schema\"") == null);
}

test "build chat completions tool call request" {
    const schema: types.StructuredSchema = .{
        .name = "extract_person",
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

    const body = try buildChatCompletionsRequest(arena.allocator(), request, schema, parsed_schema.value, .tool_call_required);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"extract_person\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_choice\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"response_format\"") == null);
}

test "build responses tool call request" {
    const schema: types.StructuredSchema = .{
        .name = "extract_person",
        .description = "Extract person.",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_schema = try parseSchemaValue(arena.allocator(), schema.schema_json);
    defer parsed_schema.deinit();

    const body = try buildResponsesRequest(arena.allocator(), request, schema, parsed_schema.value, .responses_tool_call_required);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    const payload = out.written();

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"extract_person\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_choice\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"text\"") == null);
}

const decision_fixture =
    \\{"model":"gpt-6-luna","answers":[{"type":"predicate","name":"p","probability":0.8},{"type":"choice","name":"c","choice":"yes","confidence":0.9,"probabilities":[{"value":"yes","probability":0.9},{"value":false,"probability":0.1}]},{"type":"score","name":"s","score":0.75,"confidence":0.75,"probabilities":[{"value":0,"label":"low","probability":0.25},{"value":1,"label":"high","probability":0.75}]},{"type":"refusal","name":null},{"type":"future","nested":{"kept":"owned"}}],"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5,"input_tokens_details":{"cached_tokens":1,"cache_write_tokens":0},"output_tokens_details":{"reasoning_tokens":0}},"future_root":true}
;

const decision_questions = [_]openai.QuestionParam{.{ .predicate = .{
    .type = "predicate",
    .name = "p",
    .instructions = .{ .string = "Is it true?" },
} }};
const decision_request: decisions.CreateParams = .{ .model = "gpt-6-luna", .input = "source text", .questions = &decision_questions };

const DecisionsProbe = struct {
    response: []const u8 = decision_fixture,
    status: std.http.Status = .ok,
    extras: bool = false,
    override_auth: bool = false,
    question_count: usize = 1,
    raw_question: bool = false,
    calls: usize = 0,
    failure: ?anyerror = null,

    fn check(self: *@This(), allocator: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, payload: ?[]const u8) !void {
        self.calls += 1;
        try std.testing.expectEqualStrings(if (self.extras)
            "offline://openai/v1/decisions?existing=1&a%26b=x%20y%2B%23&a%26b=two#fragment"
        else
            "https://example.test/v1/decisions", url);
        try ScriptedTransport.expectHeader(headers, "Authorization", if (self.override_auth) "custom auth" else "Bearer secret");
        try ScriptedTransport.expectHeader(headers, "Content-Type", if (self.extras) "application/custom+json" else "application/json");
        try ScriptedTransport.expectHeader(headers, "Accept", "application/json");
        if (self.extras) {
            try ScriptedTransport.expectHeader(headers, "X-Extra", "new");
            try ScriptedTransport.expectHeader(headers, "HTTP-Referer", "https://app.test");
            try ScriptedTransport.expectHeader(headers, "X-Title", "Example");
            try ScriptedTransport.expectHeader(headers, "OpenAI-Organization", "org");
            try ScriptedTransport.expectHeader(headers, "OpenAI-Project", "project");
        }
        for ([_][]const u8{ "Authorization", "Content-Type", "Accept" }) |name| {
            var count: usize = 0;
            for (headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, name)) count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload.?, .{ .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        const body = parsed.value.object;
        try std.testing.expectEqualStrings("gpt-6-luna", body.get("model").?.string);
        try std.testing.expectEqualStrings("source text", body.get("input").?.string);
        const questions = body.get("questions").?.array.items;
        try std.testing.expectEqual(self.question_count, questions.len);
        if (self.raw_question) {
            try std.testing.expectEqualStrings("future_question", questions[0].object.get("type").?.string);
            try std.testing.expectEqualStrings("unchanged", questions[0].object.get("unknown").?.string);
        } else {
            try std.testing.expectEqualStrings("predicate", questions[0].object.get("type").?.string);
            try std.testing.expectEqualStrings("Is it true?", questions[0].object.get("instructions").?.string);
            try std.testing.expectEqualStrings("p", questions[0].object.get("name").?.string);
        }
        try std.testing.expect(!body.contains("safety_identifier"));
        try std.testing.expect(!body.contains("prompt_cache_key"));
        if (self.extras) {
            try std.testing.expect(body.get("prompt_cache_options").?.object.get("future").?.bool);
            try std.testing.expectEqualStrings("kept", body.get("unknown").?.object.get("questions").?.string);
        } else try std.testing.expect(!body.contains("prompt_cache_options"));
    }

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        try std.testing.expectEqual(@as(usize, 4096), request.max_response_bytes);
        try self.check(allocator, request.url, request.headers, request.body);
        return .{ .allocator = allocator, .status = self.status, .body = try allocator.dupe(u8, self.response) };
    }

    fn observe(ctx: ?*anyopaque, _: std.http.Method, url: []const u8, headers: []const std.http.Header, payload: ?[]const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.check(std.testing.allocator, url, headers, payload) catch |err| {
            self.failure = err;
        };
    }
};

fn decisionsClient(allocator: std.mem.Allocator, probe: *DecisionsProbe) Client {
    return Client.init(.{
        .allocator = allocator,
        .io = std.testing.io,
        .api_key = "secret",
        .endpoint = .chat_completions,
        .base_url = "https://example.test/v1/",
        .max_response_bytes = 4096,
        .transport = .{ .ctx = probe, .send_fn = DecisionsProbe.send },
    });
}

fn ownedDecision(allocator: std.mem.Allocator) !decisions.Response {
    var source = std.heap.ArenaAllocator.init(allocator);
    defer source.deinit();
    var probe: DecisionsProbe = .{};
    var client = decisionsClient(allocator, &probe);
    defer client.deinit();
    var request = decision_request;
    request.input = try source.allocator().dupe(u8, request.input);
    request.questions = try source.allocator().dupe(openai.QuestionParam, request.questions);
    return client.createDecision(allocator, request);
}

fn decisionOwnershipExercise(allocator: std.mem.Allocator) !void {
    var result = try ownedDecision(allocator);
    defer result.deinit();
    try std.testing.expectEqualStrings(decision_fixture, result.raw_response);
    try std.testing.expectEqualStrings("gpt-6-luna", result.model);
    try std.testing.expectEqual(@as(u64, 5), result.usage.total_tokens);
    try std.testing.expectEqual(@as(f64, 0.8), result.value.answers[0].predicate.probability);
    try std.testing.expectEqualStrings("yes", result.value.answers[1].choice.choice.string);
    try std.testing.expect(!result.value.answers[1].choice.probabilities[1].value.boolean);
    try std.testing.expectEqualStrings("high", result.value.answers[2].score.probabilities[1].label);
    try std.testing.expectEqual(@as(f64, 0.75), result.value.answers[2].score.score);
    try std.testing.expect(result.value.answers[3] == .refusal);
    try std.testing.expectEqualStrings("owned", result.value.answers[4].raw.object.get("nested").?.object.get("kept").?.string);
}

test "decisions owns moved response beyond source and client cleanup and preserves SDK variants" {
    try decisionOwnershipExercise(std.testing.allocator);
}

fn decisionExtrasExercise(allocator: std.mem.Allocator, comptime legacy: bool, override_auth: bool) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var probe: DecisionsProbe = .{ .extras = true, .override_auth = override_auth };
    var client = decisionsClient(allocator, &probe);
    defer client.deinit();
    client.sdk.base_url = "offline://openai/v1/?existing=1#fragment";
    client.http_referer = "https://app.test";
    client.app_name = "Example";
    client.sdk.organization = "org";
    client.sdk.project = "project";
    const defaults = [_]std.http.Header{ .{ .name = "X-Extra", .value = "old" }, .{ .name = "Content-Type", .value = "old" } };
    client.sdk.default_headers = &defaults;
    if (legacy) {
        client.transport = null;
        client.sdk.http_observer = .{ .ctx = &probe, .onRequest = DecisionsProbe.observe, .onResponse = null, .onError = null };
    }
    var request = decision_request;
    request.extra_body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"prompt_cache_options\":{\"future\":true},\"unknown\":{\"questions\":\"kept\"}}", .{});
    const headers = [_]std.http.Header{
        .{ .name = "cOnTeNt-TyPe", .value = "application/custom+json" },
        .{ .name = "x-EXTRA", .value = "new" },
        .{ .name = "aUtHoRiZaTiOn", .value = "custom auth" },
    };
    request.extra_headers = headers[0..if (override_auth) 3 else 2];
    request.extra_query = &.{ .{ .name = "a&b", .value = "x y+#" }, .{ .name = "a&b", .value = "two" } };
    if (legacy) {
        if (client.createDecision(allocator, request)) |value| {
            var result = value;
            result.deinit();
            return error.ExpectedOfflineError;
        } else |err| switch (err) {
            error.UnsupportedUriScheme => {},
            else => return err,
        }
        if (probe.failure) |err| return err;
    } else {
        var result = try client.createDecision(allocator, request);
        defer result.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@intFromPtr(&defaults), @intFromPtr(client.sdk.default_headers.ptr));
}

test "decisions extras use injected and legacy observer dispatch independently of chat endpoint" {
    inline for (.{ false, true }) |legacy| {
        try decisionExtrasExercise(std.testing.allocator, legacy, false);
        try decisionExtrasExercise(std.testing.allocator, legacy, true);
    }
}

test "decisions rejects missing models question counts and reserved extras before dispatch" {
    var probe: DecisionsProbe = .{};
    var client = decisionsClient(std.testing.allocator, &probe);
    defer client.deinit();
    var request = decision_request;
    request.model = null;
    try std.testing.expectError(error.MissingModel, client.createDecision(std.testing.allocator, request));
    request.model = "";
    try std.testing.expectError(error.MissingModel, client.createDecision(std.testing.allocator, request));
    request = decision_request;
    request.questions = &.{};
    try std.testing.expectError(error.InvalidDecisionQuestions, client.createDecision(std.testing.allocator, request));
    const too_many: [401]openai.QuestionParam = @splat(decision_questions[0]);
    request.questions = &too_many;
    try std.testing.expectError(error.InvalidDecisionQuestions, client.createDecision(std.testing.allocator, request));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ "{\"questions\":null}", "{\"questions\":[]}", "{\"input\":\"other\"}", "{\"model\":\"other\"}" }) |json| {
        request = decision_request;
        request.extra_body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
        try std.testing.expectError(error.ReservedBodyField, client.createDecision(std.testing.allocator, request));
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "decisions accepts 400 questions and sends raw questions without rewriting or retries" {
    var probe: DecisionsProbe = .{ .question_count = 400 };
    var client = decisionsClient(std.testing.allocator, &probe);
    defer client.deinit();
    var request = decision_request;
    const maximum: [400]openai.QuestionParam = @splat(decision_questions[0]);
    request.questions = &maximum;
    var result = try client.createDecision(std.testing.allocator, request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw_question = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"future_question\",\"unknown\":\"unchanged\"}", .{});
    request.questions = &.{.{ .raw = raw_question }};
    probe = .{ .raw_question = true, .response = "{\"error\":{\"message\":\"unsupported question\"}}", .status = .bad_request };
    try std.testing.expectError(error.ProviderHttpError, client.createDecision(std.testing.allocator, request));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(std.http.Status.bad_request, client.lastStatus().?);
    try std.testing.expectEqualStrings(probe.response, client.lastErrorBody().?);
}

fn decisionErrorExercise(allocator: std.mem.Allocator, body: []const u8, status: std.http.Status, expected: anyerror) !void {
    var probe: DecisionsProbe = .{ .response = body, .status = status };
    var client = decisionsClient(allocator, &probe);
    defer client.deinit();
    if (client.createDecision(allocator, decision_request)) |value| {
        var result = value;
        result.deinit();
        return error.ExpectedDecisionFailure;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(expected, err);
    }
    try std.testing.expectEqual(status, client.lastStatus().?);
    try std.testing.expectEqualStrings(body, client.lastErrorBody().?);
    probe.response = decision_fixture;
    probe.status = .ok;
    var result = try client.createDecision(allocator, decision_request);
    defer result.deinit();
    try std.testing.expect(client.lastStatus() == null);
    try std.testing.expect(client.lastErrorBody() == null);
}

test "decisions HTTP malformed and duplicate field diagnostics propagate all allocation failures" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), decisionOwnershipExercise, .{});
    inline for (.{ false, true }) |legacy| {
        const Exercise = struct {
            fn run(allocator: std.mem.Allocator) !void {
                try decisionExtrasExercise(allocator, legacy, true);
            }
        };
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), Exercise.run, .{});
    }
    const Case = struct { body: []const u8, status: std.http.Status = .ok, err: anyerror };
    const cases = [_]Case{
        .{ .body = "bad question", .status = .bad_request, .err = error.ProviderHttpError },
        .{ .body = "{\"error\":{\"message\":\"denied\"}}", .err = error.ProviderHttpError },
        .{ .body = "not json", .err = error.SyntaxError },
        .{ .body = "{\"model\":\"first\",\"model\":\"duplicate\"}", .err = error.DuplicateField },
        .{ .body = "{\"answers\":[{\"type\":\"future\",\"nested\":{\"x\":1,\"x\":2}}]}", .err = error.DuplicateField },
        .{ .body = "{}", .err = error.MissingField },
    };
    for (cases) |case| {
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), decisionErrorExercise, .{ case.body, case.status, case.err });
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var probe: DecisionsProbe = .{ .response = "denied", .status = .unauthorized };
    var client = decisionsClient(failing.allocator(), &probe);
    defer client.deinit();
    try std.testing.expectError(error.OutOfMemory, client.createDecision(std.testing.allocator, decision_request));
}

const ExtrasProbe = struct {
    endpoint: Client.Endpoint,
    structured: bool,
    override_auth: bool = true,
    calls: usize = 0,
    failure: ?anyerror = null,

    fn check(self: *@This(), url: []const u8, headers: []const std.http.Header, payload: ?[]const u8) !void {
        self.calls += 1;
        const expected = if (self.endpoint == .responses)
            "offline://openai/v1/responses?existing=1&a%26b=x%20y%2B%23&a%26b=two#fragment"
        else
            "offline://openai/v1/chat/completions?existing=1&a%26b=x%20y%2B%23&a%26b=two#fragment";
        try std.testing.expectEqualStrings(expected, url);
        var authorization: usize = 0;
        var content_type: usize = 0;
        var custom: usize = 0;
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                authorization += 1;
                try std.testing.expectEqualStrings(if (self.override_auth) "aUtHoRiZaTiOn" else "Authorization", header.name);
                try std.testing.expectEqualStrings(if (self.override_auth) "custom auth" else "Bearer secret", header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                content_type += 1;
                try std.testing.expectEqualStrings("cOnTeNt-TyPe", header.name);
                try std.testing.expectEqualStrings("application/custom+json", header.value);
            }
            if (std.ascii.eqlIgnoreCase(header.name, "x-extra")) {
                custom += 1;
                try std.testing.expectEqualStrings("new", header.value);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), authorization);
        try std.testing.expectEqual(@as(usize, 1), content_type);
        try std.testing.expectEqual(@as(usize, 1), custom);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload.?, .{ .parse_numbers = false, .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        const body = parsed.value.object;
        try std.testing.expectEqualStrings("test-model", body.get("model").?.string);
        const nested = body.get("unknown").?.object;
        try std.testing.expectEqualStrings("1.234567890123456789e100", nested.get("number").?.number_string);
        try std.testing.expectEqualStrings("nested", nested.get("model").?.string);
        try std.testing.expectEqualStrings("kept", nested.get("format").?.string);
        try std.testing.expectEqualStrings("0.75", body.get("temperature").?.number_string);
        try std.testing.expect(!body.get("stream").?.bool);
        if (self.structured) {
            if (self.endpoint == .responses) {
                try std.testing.expect(body.get("text").?.object.contains("format"));
                try std.testing.expectEqualStrings("low", body.get("text").?.object.get("verbosity").?.string);
            } else try std.testing.expect(body.contains("response_format"));
        }
    }

    fn observe(ctx: ?*anyopaque, _: std.http.Method, url: []const u8, headers: []const std.http.Header, payload: ?[]const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.check(url, headers, payload) catch |err| {
            self.failure = err;
        };
    }

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        try self.check(request.url, request.headers, request.body);
        const response = if (self.endpoint == .responses) "{\"output_text\":\"ok\"}" else "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}";
        return .{ .allocator = allocator, .status = .ok, .body = try allocator.dupe(u8, response) };
    }
};

fn extrasExercise(allocator: std.mem.Allocator, endpoint: Client.Endpoint, comptime structured: bool, comptime legacy: bool, override_auth: bool) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const extra = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"unknown":{"number":1.234567890123456789e100,"model":"nested","format":"kept"},"temperature":0.75,"text":{"verbosity":"low"},"stream":false}
    , .{ .parse_numbers = false });
    var probe: ExtrasProbe = .{ .endpoint = endpoint, .structured = structured, .override_auth = override_auth };
    var client = Client.init(.{
        .allocator = allocator,
        .io = std.testing.io,
        .api_key = "secret",
        .endpoint = endpoint,
        .base_url = "offline://openai/v1/?existing=1#fragment",
        .transport = if (legacy) null else .{ .ctx = &probe, .send_fn = ExtrasProbe.send },
    });
    defer client.deinit();
    const defaults = [_]std.http.Header{
        .{ .name = "X-Extra", .value = "old" },
        .{ .name = "x-extra", .value = "stale duplicate" },
        .{ .name = "Content-Type", .value = "stale" },
    };
    client.sdk.default_headers = &defaults;
    if (legacy) client.sdk.http_observer = .{ .ctx = &probe, .onRequest = ExtrasProbe.observe, .onResponse = null, .onError = null };
    var request = plain_request;
    request.extra_body = extra;
    const overrides = [_]std.http.Header{
        .{ .name = "cOnTeNt-TyPe", .value = "application/custom+json" },
        .{ .name = "x-EXTRA", .value = "new" },
        .{ .name = "aUtHoRiZaTiOn", .value = "custom auth" },
    };
    request.extra_headers = overrides[0..if (override_auth) 3 else 2];
    request.extra_query = &.{ .{ .name = "a&b", .value = "x y+#" }, .{ .name = "a&b", .value = "two" } };
    const schema: types.StructuredSchema = .{ .name = "Test", .schema_json = "{\"type\":\"object\"}" };
    if (legacy) {
        const result = if (structured) client.completeStructured(allocator, request, schema, .{}) else client.completeText(allocator, request);
        if (result) |value| {
            var completion = value;
            completion.deinit(allocator);
            return error.ExpectedOfflineError;
        } else |err| switch (err) {
            error.UnsupportedUriScheme => {},
            else => return err,
        }
        if (probe.failure) |err| return err;
    } else {
        var completion = if (structured) try client.completeStructured(allocator, request, schema, .{}) else try client.completeText(allocator, request);
        defer completion.deinit(allocator);
        try std.testing.expectEqualStrings("ok", completion.text);
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@intFromPtr(&defaults), @intFromPtr(client.sdk.default_headers.ptr));
    try std.testing.expectEqualStrings("old", defaults[0].value);
}

test "openai extras pass through every injected and legacy observer completion path" {
    inline for (.{ Client.Endpoint.responses, .chat_completions }) |endpoint| {
        inline for (.{ false, true }) |structured| {
            inline for (.{ false, true }) |legacy| {
                try extrasExercise(std.testing.allocator, endpoint, structured, legacy, true);
                try extrasExercise(std.testing.allocator, endpoint, structured, legacy, false);
            }
        }
    }
}

test "openai extras reject envelope streaming schema collisions and header injection before dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema: types.StructuredSchema = .{ .name = "Test", .schema_json = "{\"type\":\"object\"}" };
    inline for (.{ Client.Endpoint.responses, .chat_completions }) |endpoint| {
        var script: ScriptedTransport = .{ .endpoint = endpoint, .response = "{}" };
        var client = scriptedClient(&script);
        defer client.deinit();
        inline for (.{ "{\"model\":\"other\"}", "{\"input\":[]}", "{\"messages\":[]}" }) |json| {
            var request = plain_request;
            request.extra_body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
            try std.testing.expectError(error.ReservedBodyField, client.completeText(std.testing.allocator, request));
            try std.testing.expectError(error.ReservedBodyField, client.completeStructured(std.testing.allocator, request, schema, .{}));
        }
        inline for (.{
            if (endpoint == .responses) "{\"text\":null}" else "{\"response_format\":null}",
            if (endpoint == .responses) "{\"text\":{\"format\":{}}}" else "{\"response_format\":{}}",
            "{\"tools\":[]}",
            "{\"tool_choice\":null}",
        }) |json| {
            var request = plain_request;
            request.extra_body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
            try std.testing.expectError(error.ReservedBodyField, client.completeStructured(std.testing.allocator, request, schema, .{}));
        }
        inline for (.{ "{\"stream\":true}", "{\"stream\":0}" }) |json| {
            var request = plain_request;
            request.extra_body = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
            try std.testing.expectError(error.UnsupportedStreaming, client.completeText(std.testing.allocator, request));
            try std.testing.expectError(error.UnsupportedStreaming, client.completeStructured(std.testing.allocator, request, schema, .{}));
        }
        var request = plain_request;
        request.extra_headers = &.{.{ .name = "X-Header", .value = "bad\r\nInjected: true" }};
        try std.testing.expectError(error.InvalidHeader, client.completeText(std.testing.allocator, request));
        try std.testing.expectEqual(@as(usize, 0), script.calls);
    }
}

test "openai extras clean up all injected and legacy allocation failures" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    inline for (.{ false, true }) |legacy| {
        inline for (.{ false, true }) |structured| {
            const Exercise = struct {
                fn run(allocator: std.mem.Allocator) !void {
                    try extrasExercise(allocator, .responses, structured, legacy, true);
                }
            };
            try std.testing.checkAllAllocationFailures(no_resize.allocator(), Exercise.run, .{});
        }
    }
}

const ScriptedTransport = struct {
    response: []const u8,
    status: std.http.Status = .ok,
    endpoint: Client.Endpoint = .responses,
    structured: bool = false,
    inspect_request: bool = false,
    calls: usize = 0,

    fn transport(self: *ScriptedTransport) http.Transport {
        return .{ .ctx = self, .send_fn = send };
    }

    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.inspect_request) {
            try std.testing.expectEqual(std.http.Method.POST, request.method);
            try std.testing.expectEqualStrings(if (self.endpoint == .responses)
                "https://example.test/v1/responses"
            else
                "https://example.test/v1/chat/completions", request.url);
            try std.testing.expectEqual(@as(usize, 4096), request.max_response_bytes);
            try expectHeader(request.headers, "Authorization", "Bearer secret");
            try expectHeader(request.headers, "Content-Type", "application/json");
            try expectHeader(request.headers, "Accept", "application/json");
            try expectHeader(request.headers, "X-Custom", "preserved");
            try expectHeader(request.headers, "HTTP-Referer", "https://app.test");
            try expectHeader(request.headers, "X-Title", "Example");
            try expectHeader(request.headers, "OpenAI-Organization", "org");
            try expectHeader(request.headers, "OpenAI-Project", "project");
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body.?, .{});
            defer parsed.deinit();
            const object = parsed.value.object;
            try std.testing.expectEqualStrings("test-model", object.get("model").?.string);
            try std.testing.expectEqual(@as(f64, 0.25), object.get("temperature").?.float);
            const token_field = if (self.endpoint == .responses) "max_output_tokens" else "max_tokens";
            try std.testing.expectEqual(@as(i64, 128), object.get(token_field).?.integer);
            if (!self.structured) {
                for ([_][]const u8{ "text", "response_format", "tools", "tool_choice" }) |field| {
                    try std.testing.expect(object.get(field) == null);
                }
            }
            if (self.endpoint == .responses) {
                const message = object.get("input").?.array.items[0].object;
                try std.testing.expectEqualStrings("user", message.get("role").?.string);
                try std.testing.expectEqualStrings("Hello", message.get("content").?.string);
            } else {
                const message = object.get("messages").?.array.items[0].object;
                try std.testing.expectEqualStrings("user", message.get("role").?.string);
                try std.testing.expectEqualStrings("Hello", message.get("content").?.string);
            }
        }
        return .{ .allocator = allocator, .status = self.status, .body = try allocator.dupe(u8, self.response) };
    }

    fn expectHeader(headers: []const std.http.Header, name: []const u8, value: []const u8) !void {
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return;
        }
        return error.MissingExpectedHeader;
    }
};

fn scriptedClient(script: *ScriptedTransport) Client {
    var client = Client.init(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .api_key = "secret",
        .base_url = "https://example.test/v1/",
        .endpoint = script.endpoint,
        .http_referer = "https://app.test",
        .app_name = "Example",
        .transport = script.transport(),
        .max_response_bytes = 4096,
    });
    client.sdk.default_headers = &.{.{ .name = "X-Custom", .value = "preserved" }};
    client.sdk.organization = "org";
    client.sdk.project = "project";
    return client;
}

const plain_request: Client.Request = .{
    .model = "test-model",
    .messages = &.{.{ .role = .user, .content = "Hello" }},
    .temperature = 0.25,
    .max_output_tokens = 128,
};

test "openai ordinary transport sends schema-free responses and chat requests" {
    const bodies = [_][]const u8{
        \\{"status":"completed","error":null,"output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"Hello "},{"type":"output_text","text":"world"}]},{"type":"message","content":[{"type":"output_text","text":"!"}]}],"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}
        ,
        \\{"choices":[{"finish_reason":"stop","message":{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"world!"}]}},{"message":{"content":"ignored"}}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}
        ,
    };
    inline for (.{ Client.Endpoint.responses, .chat_completions }, bodies) |endpoint, body| {
        var script: ScriptedTransport = .{ .endpoint = endpoint, .response = body, .inspect_request = true };
        var client = scriptedClient(&script);
        defer client.deinit();
        var completion = try client.completeText(std.testing.allocator, plain_request);
        defer completion.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("Hello world!", completion.text);
        try std.testing.expectEqualStrings(body, completion.raw_response);
        try std.testing.expectEqual(@as(u64, 2), completion.usage.input_tokens);
        try std.testing.expectEqual(@as(u64, 3), completion.usage.output_tokens);
        try std.testing.expectEqual(@as(u64, 5), completion.usage.total_tokens);
        try std.testing.expectEqual(@as(usize, 1), script.calls);
        try std.testing.expect(client.lastStatus() == null);
        try std.testing.expectEqual(@as(usize, 1), client.sdk.default_headers.len);
        try std.testing.expectEqualStrings("X-Custom", client.sdk.default_headers[0].name);
    }
}

test "openai ordinary transport refuses partial text and keeps diagnostics" {
    const Case = struct { endpoint: Client.Endpoint = .responses, body: []const u8, status: std.http.Status = .ok, err: anyerror };
    const cases = [_]Case{
        .{ .body = "denied", .status = .unauthorized, .err = error.ProviderHttpError },
        .{ .body = "{\"error\":{\"message\":\"bad\"}}", .err = error.ProviderHttpError },
        .{ .body = "{\"output\":[{\"content\":[{\"text\":\"partial\"},{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}", .err = error.Refusal },
        .{ .body = "{\"status\":\"incomplete\",\"output_text\":\"partial\"}", .err = error.IncompleteResponse },
        .{ .body = "{\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output_text\":\"partial\"}", .err = error.IncompleteResponse },
        .{ .body = "{\"output\":[{\"status\":\"incomplete\",\"content\":[{\"text\":\"partial\"}]}]}", .err = error.IncompleteResponse },
        .{ .body = "{\"output\":[{\"type\":\"function_call\",\"arguments\":\"not text\"}]}", .err = error.MissingOutputText },
        .{ .body = "{\"output\":42}", .err = error.InvalidProviderResponse },
        .{ .body = "not json", .err = error.SyntaxError },
        .{ .endpoint = .chat_completions, .body = "{\"choices\":[{\"message\":{\"content\":\"partial\",\"refusal\":\"no\"}}]}", .err = error.Refusal },
        .{ .endpoint = .chat_completions, .body = "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial\"}}]}", .err = error.IncompleteResponse },
        .{ .endpoint = .chat_completions, .body = "{\"choices\":[{\"finish_reason\":\"content_filter\",\"message\":{\"content\":\"partial\"}}]}", .err = error.Refusal },
        .{ .endpoint = .chat_completions, .body = "{\"choices\":[{\"message\":{\"tool_calls\":[{\"function\":{\"arguments\":\"not text\"}}]}}]}", .err = error.MissingOutputText },
    };
    for (cases) |case| {
        var script: ScriptedTransport = .{ .endpoint = case.endpoint, .response = case.body, .status = case.status };
        var client = scriptedClient(&script);
        defer client.deinit();
        try std.testing.expectError(case.err, client.completeText(std.testing.allocator, plain_request));
        try std.testing.expectEqual(case.status, client.lastStatus().?);
        try std.testing.expectEqualStrings(case.body, client.lastErrorBody().?);
        script.status = .ok;
        script.response = if (case.endpoint == .responses) "{\"output_text\":\"ok\"}" else "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}";
        var completion = try client.completeText(std.testing.allocator, plain_request);
        defer completion.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("ok", completion.text);
        try std.testing.expect(client.lastStatus() == null);
        try std.testing.expect(client.lastErrorBody() == null);
    }
}

test "openai structured transport preserves every supported mode" {
    const schema: types.StructuredSchema = .{ .name = "Person", .schema_json = "{\"type\":\"object\"}" };
    inline for (.{ Client.Endpoint.responses, .chat_completions }) |endpoint| {
        inline for (.{ types.Mode.json_schema, .json_object, .tool_call, .tool_call_required, .responses_tool_call, .responses_tool_call_required }) |mode| {
            if (modeSupported(endpoint, mode)) {
                const body = if (endpoint == .responses)
                    "{\"output\":[{\"type\":\"function_call\",\"arguments\":\"{}\"}]}"
                else
                    "{\"choices\":[{\"message\":{\"tool_calls\":[{\"function\":{\"arguments\":\"{}\"}}]}}]}";
                var script: ScriptedTransport = .{ .endpoint = endpoint, .response = body, .structured = true, .inspect_request = true };
                var client = scriptedClient(&script);
                defer client.deinit();
                var completion = try client.completeStructured(std.testing.allocator, plain_request, schema, .{ .mode = mode });
                defer completion.deinit(std.testing.allocator);
                try std.testing.expectEqualStrings("{}", completion.text);
                try std.testing.expectEqual(@as(usize, 1), script.calls);
            }
        }
    }
}

fn completionAllocationTest(allocator: std.mem.Allocator, endpoint: Client.Endpoint) !void {
    var script: ScriptedTransport = .{
        .endpoint = endpoint,
        .response = if (endpoint == .responses)
            "{\"error\":null,\"output\":[{\"content\":[{\"text\":\"ok\"}]}],\"usage\":{\"total_tokens\":3}}"
        else
            "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"total_tokens\":3}}",
    };
    var client = Client.init(.{ .allocator = allocator, .io = std.testing.io, .api_key = "offline", .endpoint = endpoint, .transport = script.transport() });
    defer client.deinit();
    var completion = try client.completeText(allocator, plain_request);
    defer completion.deinit(allocator);
    try std.testing.expectEqualStrings("ok", completion.text);
    try std.testing.expectEqual(@as(u64, 3), completion.usage.total_tokens);
}

test "openai completion and diagnostics propagate all allocation failures" {
    // Disable in-place growth so allocator bucket state cannot change the
    // allocation count between the baseline and exhaustive failure passes.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    inline for (.{ Client.Endpoint.responses, .chat_completions }) |endpoint| {
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), completionAllocationTest, .{endpoint});
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var script: ScriptedTransport = .{ .response = "{\"output\":[{\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}" };
    var client = Client.init(.{ .allocator = failing.allocator(), .io = std.testing.io, .api_key = "offline", .transport = script.transport() });
    defer client.deinit();
    // The response allocator works; allocating the owned diagnostic must fail.
    try std.testing.expectError(error.OutOfMemory, client.completeText(std.testing.allocator, plain_request));
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

test "extract output text from responses tool call" {
    const raw =
        \\{
        \\  "output": [{"type": "function_call", "name": "extract_person", "arguments": "{\"name\":\"Ada\"}"}],
        \\  "usage": {"input_tokens": 1, "output_tokens": 2, "total_tokens": 3}
        \\}
    ;

    const text = try extractOutputText(std.testing.allocator, raw);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\"}", text);
}

test "extract output text from chat tool call" {
    const raw =
        \\{
        \\  "choices": [{"message": {"tool_calls": [{"function": {"name": "extract_person", "arguments": "{\"name\":\"Ada\"}"}}]}}],
        \\  "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3}
        \\}
    ;

    const text = try extractOutputText(std.testing.allocator, raw);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\"}", text);

    const usage = try extractUsage(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(u64, 1), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 3), usage.total_tokens);
}
