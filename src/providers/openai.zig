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
            .responses => try postResponses(self, allocator, request, schema, options.mode),
            .chat_completions => try postChatCompletions(self, allocator, request, schema, options.mode),
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
    return openai.postJsonRaw(&client.sdk, "/responses", body);
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
    return openai.postJsonRaw(&client.sdk, "/chat/completions", body);
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
    var body: openai.CreateResponse = .{
        .model = request.model,
        .input = .{ .input_item_list = try inputItems(allocator, request.messages) },
        .temperature = request.temperature,
        .max_output_tokens = if (request.max_output_tokens) |value| @as(?i64, @intCast(value)) else null,
    };

    switch (mode) {
        .json_schema => body.text = .{ .format = try responsesFormat(allocator, schema, schema_value) },
        .json_object => body.text = .{ .format = .{ .response_format_json_object = .{ .type = "json_object" } } },
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
    var body: openai.CreateChatCompletionRequest = .{
        .model = request.model,
        .messages = try messagesSlice(allocator, request.messages),
        .temperature = request.temperature,
        .max_tokens = if (request.max_output_tokens) |value| @intCast(value) else null,
    };

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
        .float => |float| if (float >= 0) @intFromFloat(float) else null,
        else => null,
    };
}

fn inputItems(allocator: std.mem.Allocator, messages: []const Client.Message) ![]const openai.InputItem {
    const result = try allocator.alloc(openai.InputItem, messages.len);
    for (messages, result) |message, *out| {
        out.* = .{ .easy_input_message = .{
            .role = roleString(message.role),
            .content = if (message.images.len == 0)
                .{ .text = message.content }
            else
                .{ .parts = try responsesContentParts(allocator, message) },
        } };
    }
    return result;
}

fn messagesSlice(allocator: std.mem.Allocator, messages: []const Client.Message) ![]const openai.ChatCompletionRequestMessage {
    const result = try allocator.alloc(openai.ChatCompletionRequestMessage, messages.len);
    for (messages, result) |message, *out| {
        out.* = .{
            .role = roleString(message.role),
            .content = if (message.images.len == 0)
                .{ .string = message.content }
            else
                try chatContentParts(allocator, message),
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

fn chatContentParts(allocator: std.mem.Allocator, message: Client.Message) !std.json.Value {
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
    return .{ .text_response_format_json_schema = .{
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
