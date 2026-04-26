# `instructor.zig` API spec

Target Zig version: `0.16.0` stable APIs.

Status: v0 design. Validation is explicitly out of scope for v0. `validate.zig` or a future JSON Schema validation library can plug in later.

## Core design

`instructor.zig` uses caller-owned lifetime scopes.

- `Client` owns provider config and transport defaults.
- `Session` owns result memory for one task/batch.
- `create()` returns `T` directly.
- `Session.deinit()` frees all parsed result allocations together.
- Provider adapter owns request mutation/retry formatting.

This matches Zig style and `std.Io`: caller controls I/O, allocation, and lifetime.

## Goals

- Generate JSON Schema from comptime Zig type.
- Send schema to provider through adapter.
- Parse provider JSON text into Zig type with `std.json`.
- Retry on parse errors by appending provider-specific error feedback.
- Return `T` directly for ergonomic code.
- Free all result memory through `Session.deinit()`.
- Keep validation outside core.

## Non-goals for v0

- JSON Schema validation.
- `T.validate()` hooks.
- Streaming.
- Union extraction.
- Multi-provider parity with `instructor-go`.
- Rich error payloads.
- Full OpenAI generated SDK correctness.

## Primary user API

```zig
var client = instructor.OpenAI.init(.{
    .allocator = gpa,
    .io = init.io,
    .api_key = api_key,
});
defer client.deinit();

var session = instructor.Session.init(gpa, &client);
defer session.deinit();

const person = try session.create(Person, .{
    .model = instructor.OpenAI.default_model,
    .messages = &.{
        .{ .role = .user, .content = "Robby is 24." },
    },
}, .{});
```

`person` is valid until `session.deinit()`.

## Type-level API

```zig
pub fn Session(comptime Provider: type) type;
```

Returned type:

```zig
pub fn Session(comptime Provider: type) type {
    return struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        provider: *Provider,
        usage: Usage = .{},
        last_usage: Usage = .{},
        last_text: ?[]const u8 = null,
        last_raw_response: ?[]const u8 = null,
        hooks: Hooks = .{},

        pub fn init(allocator: std.mem.Allocator, provider: *Provider) @This();
        pub fn deinit(self: *@This()) void;

        pub fn create(
            self: *@This(),
            comptime T: type,
            request: anytype,
            comptime options: Options,
        ) !T;

        pub fn createDetailed(
            self: *@This(),
            comptime T: type,
            request: anytype,
            comptime options: Options,
        ) !CreateResult(T);

        pub fn setHooks(self: *@This(), hooks: Hooks) void;
        pub fn reset(self: *@This()) void;
    };
}
```

Convenience inference helper:

```zig
pub fn session(allocator: std.mem.Allocator, provider: anytype) Session(ProviderType(provider));
```

Possible use:

```zig
var s = instructor.session(gpa, &client);
defer s.deinit();

const person = try s.create(Person, req, .{});
```

## Why not return wrapper

Returning wrapper is safe but noisy:

```zig
var result = try instructor.create(Person, ...);
defer result.deinit();
const person = result.value;
```

Session makes lifetime explicit once and returns `T` directly:

```zig
var session = instructor.session(gpa, &client);
defer session.deinit();

const person = try session.create(Person, req, .{});
```

This is better for app code and still memory-safe.

## Lifetime rule

All allocations needed by returned `T` live in `Session` arena.

```zig
const person = try session.create(Person, req, .{});
// person.name, slices, nested arrays valid here

session.deinit();
// person invalid after this point
```

`Session.reset()` frees all prior results and usage/raw debug memory. Any previously returned `T` becomes invalid after reset.

## Client ownership

Client stores provider config and request-time defaults:

- GPA/temp allocator
- `std.Io`
- API key
- base URL override for OpenAI-compatible providers
- HTTP config

Client should not own parsed result structs. Long-lived clients must not accumulate result memory.

Example:

```zig
var client = instructor.OpenAI.init(.{
    .allocator = gpa,
    .io = init.io,
    .api_key = api_key,
    .base_url = "https://api.openai.com/v1", // override for compatible endpoints
});
defer client.deinit();
```

## Session ownership

Session owns parsed values and optional retained debug data.

```zig
var session = instructor.session(gpa, &client);
defer session.deinit();

const user = try session.create(User, user_req, .{});
const ticket = try session.create(Ticket, ticket_req, .{});
```

Both `user` and `ticket` are freed by one `session.deinit()`.

Use one session per task/batch/request scope. Do not use one global session for whole application unless intentionally retaining all results.

## Low-level one-shot API

Core functions powering `Session.create` and `Session.createDetailed`:

```zig
pub fn createWithArena(
    comptime T: type,
    temp_allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    provider: anytype,
    request: anytype,
    usage: ?*Usage,
    comptime options: Options,
) !T;

pub fn createDetailedWithArena(
    comptime T: type,
    temp_allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    provider: anytype,
    request: anytype,
    usage: ?*Usage,
    hooks: ?Hooks,
    comptime options: Options,
) !CreateResult(T);
```

These return data allocated in caller-provided arena. Caller must ensure arena outlives returned values and slices.

Example:

```zig
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();

const person = try instructor.createWithArena(
    Person,
    gpa,
    arena.allocator(),
    &client,
    req,
    null,
    .{},
);
```

## Object roots

Some provider structured-output modes require an object root. `instructor.zig` does not hide this with schema transforms. Define the object root as a Zig type and call `create` normally.

Root array:

```zig
const Item = struct {
    task: []const u8,
};

const Items = struct {
    items: []const Item,

    pub const jsonschema = .{
        .name = "Items",
        .fields = .{
            .items = .{ .description = "Extracted items." },
        },
    };
};

const result = try session.create(Items, req, .{});
const items = result.items;
```

Root union:

```zig
const Next = struct {
    action: Action,
};

const next = try session.create(Next, req, .{});
```

This mirrors Zig's explicit-type style and avoids dynamic wrapper/unwrapper state.

## Options

```zig
pub const Options = struct {
    mode: Mode = .json_schema,
    max_retries: u8 = 3,
    schema_options: jsonschema.Options = jsonschema.strict_options,
    parse_options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
    },
};

pub const Mode = enum {
    json_schema,
    json_object,
    tool_call,
    tool_call_required,
    responses_tool_call,
    responses_tool_call_required,
};
```

`parse_options.allocate = .alloc_always` recommended so returned `T` does not borrow provider response text.

Modes:

| Mode | Endpoint | Behavior |
| --- | --- | --- |
| `.json_schema` | Responses or Chat Completions | Provider-native structured outputs. |
| `.json_object` | Responses or Chat Completions | JSON mode fallback. |
| `.tool_call` | Chat Completions | Sends `T` as function tool and parses first tool-call arguments. |
| `.tool_call_required` | Chat Completions | Same, with forced function choice. |
| `.responses_tool_call` | Responses | Sends `T` as Responses function tool and parses first function-call arguments. |
| `.responses_tool_call_required` | Responses | Same, with forced function choice. |

Provider adapters may reject unsupported endpoint/mode combinations with `error.UnsupportedMode`.

## Validation policy

V0 does not validate schema constraints after parse.

Reason: validation deserves separate library and API. `instructor.zig` should orchestrate schema, provider calls, parsing, and retry, not become validator.

Layering:

- `jsonschema.zig`: emit schemas only.
- `validate.zig` or future lib: validate JSON/value against schema.
- `openai.zig`: HTTP/API types and client.
- `instructor.zig`: schema -> provider -> parse -> retry.

Future validation entry point may be separate:

```zig
pub fn createValidated(
    comptime T: type,
    session: anytype,
    request: anytype,
    validator: anytype,
    comptime options: Options,
) !T;
```

Validator contract can be decided later.

## Usage

```zig
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void;
};
```

Session accumulates usage across calls:

```zig
const user = try session.create(User, req1, .{});
const ticket = try session.create(Ticket, req2, .{});

std.debug.print("tokens: {}\n", .{session.usage.total_tokens});
```

Per-call usage is available through `createDetailed()` and `session.last_usage`:

```zig
const result = try session.createDetailed(User, req, .{});
std.debug.print("call tokens: {}\n", .{result.usage.total_tokens});
```

`session.last_text` and `session.last_raw_response` point into the session arena and are replaced by the next successful call.

## Hooks

Hooks use plain function pointers and optional context.

```zig
pub const HookEvent = enum {
    request_start,
    response_received,
    parse_error,
    retry,
    completion_done,
};

pub const HookInfo = struct {
    attempt: usize = 0,
    schema_name: ?[]const u8 = null,
    response_text: ?[]const u8 = null,
    raw_response: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    usage: Usage = .{},
};

pub const HookFn = *const fn (?*anyopaque, HookEvent, HookInfo) void;

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    on_event: ?HookFn = null,
};
```

Example:

```zig
const State = struct {
    fn onEvent(ctx: ?*anyopaque, event: instructor.HookEvent, info: instructor.HookInfo) void {
        _ = ctx;
        std.debug.print("{s} attempt={}\n", .{ @tagName(event), info.attempt });
    }
};

session.setHooks(.{ .on_event = State.onEvent });
```

## Detailed result

```zig
pub fn CreateResult(comptime T: type) type {
    return struct {
        value: T,
        text: []const u8,
        raw_response: []const u8,
        usage: Usage = .{},
    };
}
```

`text` and `raw_response` are copied into the result arena. With `Session`, they live until `reset()` or `deinit()`.

## Provider adapter pattern

Provider adapters are duck-typed. No virtual table or interface object required.

Provider must implement:

```zig
pub fn completeStructured(
    self: *Provider,
    allocator: std.mem.Allocator,
    request: Request,
    schema: instructor.StructuredSchema,
    comptime options: instructor.Options,
) !instructor.Completion;

pub fn appendRetry(
    self: *Provider,
    allocator: std.mem.Allocator,
    request: *Request,
    retry: instructor.RetryMessage,
) !void;
```

Provider may optionally implement:

```zig
pub fn deinitRequest(
    self: *Provider,
    allocator: std.mem.Allocator,
    request: *Request,
) void;
```

`createWithArena()` copies user request into mutable local `req`. Retry hooks mutate local request. If `deinitRequest` exists, core calls it before returning.

Provider receives `allocator` for temp/request-copy allocations, not parsed result allocations unless adapter intentionally writes into session arena. Returned `Completion` buffers are freed by core after parse.

`appendRetry` receives borrowed slices. If provider keeps `retry.failed_response` or `retry.error_message` after returning, it must copy them with the provided allocator and release them from `deinitRequest`.

### Structured schema passed to providers

```zig
pub const StructuredSchema = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    schema_json: []const u8,
    strict: bool = true,
};
```

`schema_json` is borrowed and valid only during `completeStructured` call.

### Provider completion returned to core

```zig
pub const Completion = struct {
    text: []u8,
    raw_response: []u8,
    usage: Usage = .{},

    pub fn deinit(self: *Completion, allocator: std.mem.Allocator) void;
};
```

`text` and `raw_response` are owned by caller after return and allocated by allocator passed to `completeStructured`.

Core first parses `text` into a temporary per-attempt arena to avoid failed-attempt allocations leaking into the session arena. On success, core parses again into the session/result arena with `.alloc_always`, then frees completion buffers.

### Retry message

```zig
pub const RetryMessage = struct {
    failed_response: []const u8,
    error_message: []const u8,
};
```

Default parse retry text:

```text
JSON parsing failed: <error>. Return only valid JSON matching the schema.
```

Provider adapters decide how to append this. OpenAI-style adapters should append:

1. assistant message containing failed model text
2. user message containing error feedback

## OpenAI provider v0 shape

The OpenAI adapter should use minimal hand-written request until generated `openai.zig` exposes usable request/response/auth APIs.

```zig
pub const OpenAI = struct {
    pub const default_model = "gpt-5.4-mini";

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
};
```

Provider responsibilities:

- Convert `StructuredSchema` to OpenAI `text.format = { type: "json_schema", name, schema, strict }` for Responses API.
- Convert `StructuredSchema` to Chat Completions `response_format = { type: "json_schema", json_schema: { name, schema, strict } }` for OpenRouter-compatible APIs.
- Convert `StructuredSchema` to Chat Completions function tools for `.tool_call` and `.tool_call_required` modes.
- Convert `StructuredSchema` to Responses function tools for `.responses_tool_call` and `.responses_tool_call_required` modes.
- Convert `.json_object` to provider JSON object format.
- Emit endpoint-specific token fields: `max_output_tokens` for Responses, `max_tokens` for Chat Completions.
- Add auth headers.
- Extract output text.
- Extract usage.
- Preserve provider HTTP/shape error status/body for diagnostics via `lastStatus()` and `lastErrorBody()`.
- Implement `appendRetry` by appending messages and copying borrowed retry slices.

### OpenRouter-compatible config

```zig
var client = instructor.OpenAI.init(.{
    .allocator = gpa,
    .io = init.io,
    .api_key = init.environ_map.get("OPENROUTER_API_KEY") orelse return error.MissingApiKey,
    .base_url = "https://openrouter.ai/api/v1",
    .endpoint = .chat_completions,
    .http_referer = "https://github.com/h0rv/instructor.zig",
    .app_name = "instructor.zig",
});
```

Free OpenRouter models can be used by setting `.model` in the request to the model slug.

## Core flow

```text
session.create(T, request, options)
  session.createDetailed(T, request, options)
  return result.value

session.createDetailed(T, request, options)
  createDetailedWithArena(T, temp_allocator, session.arena.allocator(), provider, request, &session.usage, session.hooks, options)
  save result.usage/text/raw_response as session.last_*

createDetailedWithArena(T, temp_allocator, result_allocator, provider, request, usage_out, hooks, options)
  req = mutable copy(request)
  schema = jsonschema.toolSchemaAlloc(T, temp_allocator, options.schema_options)
  schema = { name, description, schema_json, strict = true }
  emit request_start

  for attempt in 0..max_retries:
    completion = provider.completeStructured(temp_allocator, req, schema, options)
    usage_out.add(completion.usage)
    emit response_received

    parse_check = std.json.parseFromSliceLeaky(T, temp_attempt_arena, completion.text, options.parse_options)
    if parse ok:
      copy completion.text/raw_response into result_allocator
      value = std.json.parseFromSliceLeaky(T, result_allocator, copied_text, options.parse_options)
      emit completion_done
      completion.deinit(temp_allocator)
      return .{ value, text, raw_response, usage }

    emit parse_error
    completion.deinit(temp_allocator)
    if no attempts remain:
      return error.MaxRetriesExceeded

    provider.appendRetry(temp_allocator, &req, .{ failed_response, parse_error_message })
    emit retry
```

`createWithArena()` follows the same parse/retry flow but returns only `T` and does not retain response text/raw response.

## Error model and diagnostics

```zig
pub const Error = error{
    MaxRetriesExceeded,
    UnsupportedMode,
    MissingOutputText,
    InvalidProviderResponse,
};
```

Provider adapters can return transport/provider-specific errors too.

Zig errors have no payload, so providers expose diagnostics separately:

```zig
const value = session.create(T, req, .{}) catch |err| {
    instructor.printError(err, &client);
    return err;
};
```

Low-level writer API uses `std.Io.Writer`:

```zig
try instructor.writeError(writer, err, &client);
```

Provider diagnostics include optional status/body through:

```zig
pub fn diagnostic(self: *const Provider) instructor.Diagnostic;
```

## Improvements over Go implementation

- No reflection-based request mutation. Provider adapters own retry mutation.
- No runtime schema option branching for compile-time schema shape.
- Direct `T` return with session-owned lifetime.
- Client does not leak parsed results.
- Provider request types stay concrete.
- Validation not mixed into core orchestration.

## Current scope

- Clean Zig `0.16.0` library build.
- Session-owned direct `T` API.
- Detailed result API for raw response, response text, and per-call usage.
- Hook API for request/response/parse/retry/completion events.
- Fake provider tests for success, retry, detailed result, and hooks.
- OpenAI-compatible HTTP provider for Responses and Chat Completions.
- Optional validation integration later.
