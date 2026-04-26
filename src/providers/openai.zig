const std = @import("std");
const types = @import("../core/types.zig");
const Options = @import("../core/options.zig").Options;

pub const Client = struct {
    pub const default_model = "gpt-5.4-mini";

    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    base_url: []const u8 = "https://api.openai.com/v1",
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
        return .{
            .allocator = config.allocator,
            .io = config.io,
            .api_key = config.api_key,
            .base_url = config.base_url,
            .endpoint = config.endpoint,
            .http_referer = config.http_referer,
            .app_name = config.app_name,
        };
    }

    pub fn deinit(self: *Client) void {
        self.clearLastError();
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

        const payload = switch (self.endpoint) {
            .responses => try buildResponsesPayload(allocator, request, schema),
            .chat_completions => try buildChatCompletionsPayload(allocator, request, schema),
        };
        defer allocator.free(payload);

        var raw_response_writer: std.Io.Writer.Allocating = .init(allocator);
        defer raw_response_writer.deinit();

        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth);

        const url = try joinUrl(allocator, self.base_url, switch (self.endpoint) {
            .responses => "responses",
            .chat_completions => "chat/completions",
        });
        defer allocator.free(url);

        var http_client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer http_client.deinit();

        var headers_buf: [4]std.http.Header = undefined;
        var headers_len: usize = 0;
        headers_buf[headers_len] = .{ .name = "Authorization", .value = auth };
        headers_len += 1;
        headers_buf[headers_len] = .{ .name = "Accept", .value = "application/json" };
        headers_len += 1;
        if (self.http_referer) |http_referer| {
            headers_buf[headers_len] = .{ .name = "HTTP-Referer", .value = http_referer };
            headers_len += 1;
        }
        if (self.app_name) |app_name| {
            headers_buf[headers_len] = .{ .name = "X-Title", .value = app_name };
            headers_len += 1;
        }
        const headers = headers_buf[0..headers_len];

        const fetch_result = try http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &raw_response_writer.writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = headers,
        });

        const raw_response = try raw_response_writer.toOwnedSlice();
        errdefer allocator.free(raw_response);

        if (fetch_result.status.class() != .success or try hasProviderError(allocator, raw_response)) {
            self.last_status = fetch_result.status;
            self.last_error_body = try self.allocator.dupe(u8, raw_response);
            return Error.ProviderHttpError;
        }

        const text = extractOutputText(allocator, raw_response) catch |err| {
            self.last_status = fetch_result.status;
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

pub fn buildResponsesPayload(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{");
    try writeFieldName(writer, "model");
    try writeJsonString(writer, request.model);

    try writer.writeAll(",");
    try writeMessagesField(writer, "input", request.messages);

    try writer.writeAll(",");
    try writeFieldName(writer, "text");
    try writer.writeAll("{\"format\":");
    try writeJsonSchemaFormat(writer, schema, .responses);
    try writer.writeAll("}");

    try writeCommonRequestFields(writer, request, .responses);

    try writer.writeAll("}");
    return out.toOwnedSlice();
}

pub fn buildChatCompletionsPayload(
    allocator: std.mem.Allocator,
    request: Client.Request,
    schema: types.StructuredSchema,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{");
    try writeFieldName(writer, "model");
    try writeJsonString(writer, request.model);

    try writer.writeAll(",");
    try writeMessagesField(writer, "messages", request.messages);

    try writer.writeAll(",");
    try writeFieldName(writer, "response_format");
    try writeJsonSchemaFormat(writer, schema, .chat_completions);

    try writeCommonRequestFields(writer, request, .chat_completions);

    try writer.writeAll("}");
    return out.toOwnedSlice();
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

fn writeMessagesField(writer: *std.Io.Writer, field_name: []const u8, messages: []const Client.Message) !void {
    try writeFieldName(writer, field_name);
    try writer.writeAll("[");
    for (messages, 0..) |message, i| {
        if (i != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeFieldName(writer, "role");
        try writeJsonString(writer, roleString(message.role));
        try writer.writeAll(",");
        try writeFieldName(writer, "content");
        try writeJsonString(writer, message.content);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeJsonSchemaFormat(writer: *std.Io.Writer, schema: types.StructuredSchema, endpoint: Client.Endpoint) !void {
    try writer.writeAll("{");
    try writeFieldName(writer, "type");
    try writeJsonString(writer, "json_schema");

    switch (endpoint) {
        .responses => {
            try writer.writeAll(",");
            try writeFieldName(writer, "name");
            try writeJsonString(writer, schema.name);
            if (schema.description) |description| {
                try writer.writeAll(",");
                try writeFieldName(writer, "description");
                try writeJsonString(writer, description);
            }
            try writer.writeAll(",");
            try writeFieldName(writer, "strict");
            try writer.writeAll(if (schema.strict) "true" else "false");
            try writer.writeAll(",");
            try writeFieldName(writer, "schema");
            try writer.writeAll(schema.schema_json);
        },
        .chat_completions => {
            try writer.writeAll(",");
            try writeFieldName(writer, "json_schema");
            try writer.writeAll("{");
            try writeFieldName(writer, "name");
            try writeJsonString(writer, schema.name);
            if (schema.description) |description| {
                try writer.writeAll(",");
                try writeFieldName(writer, "description");
                try writeJsonString(writer, description);
            }
            try writer.writeAll(",");
            try writeFieldName(writer, "strict");
            try writer.writeAll(if (schema.strict) "true" else "false");
            try writer.writeAll(",");
            try writeFieldName(writer, "schema");
            try writer.writeAll(schema.schema_json);
            try writer.writeAll("}");
        },
    }

    try writer.writeAll("}");
}

fn writeCommonRequestFields(writer: *std.Io.Writer, request: Client.Request, endpoint: Client.Endpoint) !void {
    if (request.temperature) |temperature| {
        try writer.writeAll(",");
        try writeFieldName(writer, "temperature");
        try writer.print("{}", .{temperature});
    }

    if (request.max_output_tokens) |max_output_tokens| {
        try writer.writeAll(",");
        try writeFieldName(writer, switch (endpoint) {
            .responses => "max_output_tokens",
            .chat_completions => "max_tokens",
        });
        try writer.print("{}", .{max_output_tokens});
    }
}

fn joinUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, path });
}

fn roleString(role: Client.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
    };
}

fn writeFieldName(writer: *std.Io.Writer, name: []const u8) !void {
    try writeJsonString(writer, name);
    try writer.writeAll(":");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "build responses payload writes raw schema" {
    const schema: types.StructuredSchema = .{
        .name = "Person",
        .description = "Extract person.",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
    };

    const payload = try buildResponsesPayload(std.testing.allocator, request, schema);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"Person\"") != null);
}

test "build chat completions payload uses chat max token field" {
    const schema: types.StructuredSchema = .{
        .name = "Person",
        .schema_json = "{\"type\":\"object\"}",
    };
    const request: Client.Request = .{
        .model = Client.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
        .max_output_tokens = 128,
    };

    const payload = try buildChatCompletionsPayload(std.testing.allocator, request, schema);
    defer std.testing.allocator.free(payload);

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
