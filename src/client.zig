const std = @import("std");
const jsonschema = @import("jsonschema");
const core = @import("core/create.zig");
const types = @import("core/types.zig");
const options_mod = @import("core/options.zig");
const openai = @import("providers/openai.zig");
const anthropic = @import("providers/anthropic.zig");
const http = @import("transport.zig");
const request_options = @import("request_options.zig");
pub const QueryParam = request_options.QueryParam;

pub const Provider = enum { openai, anthropic };
pub const Role = enum { system, user, assistant };
pub const Message = struct {
    role: Role,
    content: []const u8,
};

/// A prompt is appended as a user message after any supplied conversation.
/// All input strings are borrowed only for the duration of the call.
const Request = struct {
    prompt: ?[]const u8 = null,
    messages: []const Message = &.{},
    model: ?[]const u8 = null,
    max_output_tokens: ?u32 = null,
    temperature: ?f64 = null,
    extra_body: ?std.json.Value = null,
    extra_headers: []const std.http.Header = &.{},
    extra_query: []const QueryParam = &.{},
};

pub const OpenAIConfig = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.openai.com/v1",
    endpoint: openai.Client.Endpoint = .responses,
    http_referer: ?[]const u8 = null,
    app_name: ?[]const u8 = null,
};

pub const AnthropicConfig = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.anthropic.com",
    max_tokens: u32 = 4096,
};

pub const Backend = union(Provider) {
    openai: OpenAIConfig,
    anthropic: AnthropicConfig,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Backend,
    extra_body: ?std.json.Value = null,
    extra_query: []const QueryParam = &.{},
    /// Additional headers are copied during initialization.
    headers: []const std.http.Header = &.{},
    model: ?[]const u8 = null,
    /// Borrowed; the client never destroys an injected transport's context.
    transport: ?http.Transport = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
    hooks: ?types.Hooks = null,
};

pub const EnvConfig = struct {
    provider: Provider,
    extra_body: ?std.json.Value = null,
    extra_query: []const QueryParam = &.{},
    headers: []const std.http.Header = &.{},
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    endpoint: openai.Client.Endpoint = .responses,
    transport: ?http.Transport = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
    hooks: ?types.Hooks = null,
};

/// These options are compile-time because schema generation depends on them.
/// An omitted schema profile uses the selected provider's defaults.
pub const ParseOptions = struct {
    mode: types.Mode = .json_schema,
    max_retries: u8 = 3,
    validate: bool = true,
    schema_options: ?jsonschema.Options = null,
    parse_options: std.json.ParseOptions = .{ .allocate = .alloc_always },
};

/// Owns response data independently of the client. Do not copy an active owner.
/// The backing allocator must outlive the result. Moving the owner is safe.
pub const Response = struct {
    arena: *std.heap.ArenaAllocator,
    text: []const u8,
    raw_response: []const u8,
    usage: types.Usage,
    provider: Provider,
    model: []const u8,

    pub fn deinit(self: *Response) void {
        destroyArena(self.arena);
        self.* = undefined;
    }
};

pub fn Owned(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,
        text: []const u8,
        raw_response: []const u8,
        usage: types.Usage,
        provider: Provider,
        model: []const u8,

        pub fn deinit(self: *@This()) void {
            destroyArena(self.arena);
            self.* = undefined;
        }
    };
}

const NativeBackend = union(Provider) {
    openai: openai.Client,
    anthropic: anthropic.Client,
};

/// Buffered text completion and typed extraction through one request API.
/// Configuration strings are copied. I/O and injected contexts are borrowed.
/// Calls on a client are synchronous and must not run concurrently.
pub const Client = struct {
    _state: *State,
    messages: Messages,
    responses: Responses,

    pub fn init(config: Config) !Client {
        return wrap(try State.init(config));
    }

    pub fn fromEnv(init_context: std.process.Init, config: EnvConfig) !Client {
        return wrap(try State.fromEnv(init_context, config));
    }

    fn wrap(value: State) !Client {
        var state = value;
        errdefer state.deinit();
        const pointer = try state.allocator.create(State);
        pointer.* = state;
        return .{
            ._state = pointer,
            .messages = .{ .state = pointer },
            .responses = .{ .state = pointer },
        };
    }

    pub fn deinit(self: *Client) void {
        const allocator = self._state.allocator;
        self._state.deinit();
        allocator.destroy(self._state);
        self.* = undefined;
    }

    pub fn diagnostic(self: *const Client) types.Diagnostic {
        return self._state.diagnostic();
    }
};

// Resource fields refer to this stable allocation, never to the outer handle.
const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: NativeBackend,
    model: []const u8,
    config_arena: *std.heap.ArenaAllocator,
    owned_transport: ?http.StdHttp,
    hooks: ?types.Hooks,
    extra_body: ?std.json.Value,
    extra_query: []const QueryParam,

    pub fn init(config: Config) !State {
        const arena = try createArena(config.allocator);
        errdefer destroyArena(arena);
        const strings = arena.allocator();

        var owned_transport: ?http.StdHttp = null;
        if (config.transport == null) {
            owned_transport = try http.StdHttp.init(config.allocator, config.io);
        }
        errdefer if (owned_transport) |*transport| transport.deinit();
        const transport = config.transport orelse owned_transport.?.transport();

        const default_model = switch (config.provider) {
            .openai => openai.Client.default_model,
            .anthropic => anthropic.Client.default_model,
        };
        const model = config.model orelse default_model;
        if (model.len == 0) return error.MissingModel;
        const owned_model = try strings.dupe(u8, model);

        const headers = try strings.alloc(std.http.Header, config.headers.len);
        for (config.headers, headers) |header, *copy| {
            copy.* = .{ .name = try strings.dupe(u8, header.name), .value = try strings.dupe(u8, header.value) };
        }

        const extra_body = try request_options.cloneExtraBody(strings, config.extra_body);
        const extra_query = try request_options.cloneQuery(strings, config.extra_query);

        var backend: NativeBackend = switch (config.provider) {
            .openai => |provider| .{ .openai = openai.Client.init(.{
                .allocator = config.allocator,
                .io = config.io,
                .api_key = try strings.dupe(u8, provider.api_key),
                .base_url = try strings.dupe(u8, provider.base_url),
                .endpoint = provider.endpoint,
                .http_referer = try optionalDupe(strings, provider.http_referer),
                .app_name = try optionalDupe(strings, provider.app_name),
                .transport = transport,
                .max_response_bytes = config.max_response_bytes,
            }) },
            .anthropic => |provider| .{ .anthropic = anthropic.Client.init(.{
                .allocator = config.allocator,
                .io = config.io,
                .api_key = try strings.dupe(u8, provider.api_key),
                .base_url = try strings.dupe(u8, provider.base_url),
                .max_tokens = provider.max_tokens,
                .transport = transport,
                .max_response_bytes = config.max_response_bytes,
            }) },
        };
        switch (backend) {
            inline else => |*provider| provider.sdk.default_headers = headers,
        }
        // All fallible allocations occur before a provider owns resources.
        // Provider initialization itself is allocation-free.
        return .{
            .allocator = config.allocator,
            .io = config.io,
            .backend = backend,
            .model = owned_model,
            .config_arena = arena,
            .owned_transport = owned_transport,
            .hooks = config.hooks,
            .extra_body = extra_body,
            .extra_query = extra_query,
        };
    }

    /// Reads only the supplied process environment, not hidden global state.
    /// Servers can use init with credentials supplied by their own application.
    pub fn fromEnv(init_context: std.process.Init, config: EnvConfig) !State {
        if (config.provider == .anthropic and config.endpoint != .responses) {
            return error.UnsupportedControl;
        }
        const key_name = switch (config.provider) {
            .openai => "OPENAI_API_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
        };
        const key = init_context.environ_map.get(key_name) orelse return error.MissingApiKey;
        if (key.len == 0) return error.MissingApiKey;
        return init(.{
            .allocator = init_context.gpa,
            .io = init_context.io,
            .provider = switch (config.provider) {
                .openai => .{ .openai = .{
                    .api_key = key,
                    .base_url = config.base_url orelse "https://api.openai.com/v1",
                    .endpoint = config.endpoint,
                } },
                .anthropic => .{ .anthropic = .{
                    .api_key = key,
                    .base_url = config.base_url orelse "https://api.anthropic.com",
                } },
            },
            .model = config.model,
            .headers = config.headers,
            .extra_body = config.extra_body,
            .extra_query = config.extra_query,
            .transport = config.transport,
            .max_response_bytes = config.max_response_bytes,
            .hooks = config.hooks,
        });
    }

    pub fn deinit(self: *State) void {
        switch (self.backend) {
            inline else => |*provider| provider.deinit(),
        }
        if (self.owned_transport) |*transport| transport.deinit();
        destroyArena(self.config_arena);
        self.* = undefined;
    }

    pub fn diagnostic(self: *const State) types.Diagnostic {
        return switch (self.backend) {
            inline else => |*provider| provider.diagnostic(),
        };
    }

    fn createRequest(self: *State, input: Request) !Response {
        self.clearLastError();
        const arena = try createArena(self.allocator);
        errdefer destroyArena(arena);
        const allocator = arena.allocator();
        const request = try self.withDefaults(allocator, input);
        const conversation = try self.prepare(allocator, request);
        const model = try allocator.dupe(u8, request.model orelse self.model);

        if (self.hooks) |hooks| hooks.emit(.request_start, .{});
        const completion = switch (self.backend) {
            .openai => |*provider| try provider.completeText(allocator, try openaiRequest(allocator, request, model, conversation)),
            .anthropic => |*provider| try provider.completeText(allocator, try anthropicRequest(allocator, request, model, conversation)),
        };
        if (self.hooks) |hooks| {
            hooks.emit(.response_received, .{ .response_text = completion.text, .raw_response = completion.raw_response, .usage = completion.usage });
            hooks.emit(.completion_done, .{ .response_text = completion.text, .raw_response = completion.raw_response, .usage = completion.usage });
        }
        return .{
            .arena = arena,
            .text = completion.text,
            .raw_response = completion.raw_response,
            .usage = completion.usage,
            .provider = std.meta.activeTag(self.backend),
            .model = model,
        };
    }

    fn parseRequest(self: *State, comptime T: type, request: Request, comptime options: ParseOptions) !Owned(T) {
        self.clearLastError();
        const arena = try createArena(self.allocator);
        errdefer destroyArena(arena);
        const allocator = arena.allocator();
        const result = try self.parseDetailedInto(T, allocator, request, options);
        const model = try allocator.dupe(u8, request.model orelse self.model);
        return .{
            .arena = arena,
            .value = result.value,
            .text = result.text,
            .raw_response = result.raw_response,
            .usage = result.usage,
            .provider = std.meta.activeTag(self.backend),
            .model = model,
        };
    }

    /// The caller owns result memory. Use an arena and release it as a group.
    /// Results never borrow the temporary request buffers or the client.
    fn parseIntoRequest(self: *State, comptime T: type, result_allocator: std.mem.Allocator, request: Request, comptime options: ParseOptions) !T {
        return (try self.parseDetailedInto(T, result_allocator, request, options)).value;
    }

    fn parseDetailedInto(self: *State, comptime T: type, result_allocator: std.mem.Allocator, input: Request, comptime options: ParseOptions) !types.CreateResult(T) {
        self.clearLastError();
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const allocator = temporary.allocator();
        const request = try self.withDefaults(allocator, input);
        const conversation = try self.prepare(allocator, request);
        const model = request.model orelse self.model;
        return switch (self.backend) {
            .openai => |*provider| core.createDetailedWithArena(T, allocator, result_allocator, provider, try openaiRequest(allocator, request, model, conversation), null, self.hooks, extractionOptions(.openai, options)),
            .anthropic => |*provider| core.createDetailedWithArena(T, allocator, result_allocator, provider, try anthropicRequest(allocator, request, model, conversation), null, self.hooks, extractionOptions(.anthropic, options)),
        };
    }

    fn withDefaults(self: *const State, allocator: std.mem.Allocator, input: Request) !Request {
        var request = input;
        request.extra_body = try request_options.mergeExtraBody(allocator, self.extra_body, input.extra_body);
        request.extra_query = try request_options.mergeQuery(allocator, self.extra_query, input.extra_query);
        return request;
    }

    fn clearLastError(self: *State) void {
        switch (self.backend) {
            inline else => |*provider| provider.clearLastError(),
        }
    }

    fn prepare(self: *const State, allocator: std.mem.Allocator, request: Request) ![]const Message {
        if ((request.model orelse self.model).len == 0) return error.MissingModel;
        if (request.messages.len == 0 and request.prompt == null) return error.MissingInput;
        if (request.max_output_tokens == 0) return error.InvalidMaxOutputTokens;
        if (request.temperature) |temperature| {
            if (std.meta.activeTag(self.backend) == .anthropic) return error.UnsupportedControl;
            if (!std.math.isFinite(temperature) or temperature < 0 or temperature > 2) return error.InvalidTemperature;
        }
        const conversation = try allocator.alloc(Message, request.messages.len + @intFromBool(request.prompt != null));
        @memcpy(conversation[0..request.messages.len], request.messages);
        if (request.prompt) |prompt| conversation[request.messages.len] = .{ .role = .user, .content = prompt };
        return conversation;
    }
};

const ResourceKind = enum { messages, responses };

pub const MessageCreateParams = struct {
    messages: []const Message,
    extra_body: ?std.json.Value = null,
    extra_headers: []const std.http.Header = &.{},
    extra_query: []const QueryParam = &.{},
    model: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f64 = null,
};

/// Text input is supported here. Use Messages for a conversation history.
pub const ResponseCreateParams = struct {
    input: []const u8,
    extra_body: ?std.json.Value = null,
    extra_headers: []const std.http.Header = &.{},
    extra_query: []const QueryParam = &.{},
    model: ?[]const u8 = null,
    max_output_tokens: ?u32 = null,
    temperature: ?f64 = null,
};

pub const Messages = Resource(.messages);
pub const Responses = Resource(.responses);

/// Resource fields borrow stable client state. Moving the outer client does not
/// invalidate a resource. Resources must not outlive their client owner.
fn Resource(comptime kind: ResourceKind) type {
    const Params = switch (kind) {
        .messages => MessageCreateParams,
        .responses => ResponseCreateParams,
    };
    return struct {
        state: *State,

        pub fn create(self: @This(), params: Params) !Response {
            return self.state.createRequest(normalize(params));
        }

        pub fn parse(self: @This(), comptime T: type, params: Params) !Owned(T) {
            return self.parseWith(T, params, .{});
        }

        pub fn parseWith(self: @This(), comptime T: type, params: Params, comptime options: ParseOptions) !Owned(T) {
            return self.state.parseRequest(T, normalize(params), options);
        }

        pub fn parseInto(self: @This(), comptime T: type, allocator: std.mem.Allocator, params: Params) !T {
            return self.parseIntoWith(T, allocator, params, .{});
        }

        pub fn parseIntoWith(self: @This(), comptime T: type, allocator: std.mem.Allocator, params: Params, comptime options: ParseOptions) !T {
            return self.state.parseIntoRequest(T, allocator, normalize(params), options);
        }

        fn normalize(params: Params) Request {
            return switch (kind) {
                .messages => .{
                    .messages = params.messages,
                    .model = params.model,
                    .max_output_tokens = params.max_tokens,
                    .temperature = params.temperature,
                    .extra_body = params.extra_body,
                    .extra_headers = params.extra_headers,
                    .extra_query = params.extra_query,
                },
                .responses => .{
                    .prompt = params.input,
                    .model = params.model,
                    .max_output_tokens = params.max_output_tokens,
                    .temperature = params.temperature,
                    .extra_body = params.extra_body,
                    .extra_headers = params.extra_headers,
                    .extra_query = params.extra_query,
                },
            };
        }
    };
}

fn extractionOptions(comptime provider: Provider, comptime options: ParseOptions) options_mod.Options {
    return .{
        .mode = options.mode,
        .max_retries = options.max_retries,
        .validate = options.validate,
        .schema_options = options.schema_options orelse switch (provider) {
            .openai => options_mod.openai_schema_options,
            .anthropic => anthropic.anthropic_schema_options,
        },
        .parse_options = options.parse_options,
    };
}

fn openaiRequest(allocator: std.mem.Allocator, request: Request, model: []const u8, messages: []const Message) !openai.Client.Request {
    const native = try allocator.alloc(openai.Client.Message, messages.len);
    for (messages, native) |message, *target| {
        target.* = .{ .role = switch (message.role) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
        }, .content = message.content };
    }
    return .{ .model = model, .messages = native, .temperature = request.temperature, .max_output_tokens = request.max_output_tokens, .extra_body = request.extra_body, .extra_headers = request.extra_headers, .extra_query = request.extra_query };
}

fn anthropicRequest(allocator: std.mem.Allocator, request: Request, model: []const u8, messages: []const Message) !anthropic.Client.Request {
    const native = try allocator.alloc(anthropic.Client.Message, messages.len);
    for (messages, native) |message, *target| {
        target.* = .{ .role = switch (message.role) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
        }, .content = message.content };
    }
    return .{ .model = model, .messages = native, .max_tokens = request.max_output_tokens, .extra_body = request.extra_body, .extra_headers = request.extra_headers, .extra_query = request.extra_query };
}

fn createArena(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const allocator = arena.child_allocator;
    arena.deinit();
    allocator.destroy(arena);
}

fn optionalDupe(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text_value| try allocator.dupe(u8, text_value) else null;
}

test {
    _ = @import("client_tests.zig");
}
