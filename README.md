# instructor.zig

[![Zig Version](https://img.shields.io/badge/zig-0.16.0%2B-orange.svg)](https://ziglang.org/download/)

Typed structured outputs for Zig.

Targets Zig `0.16.0` stable APIs.

Define a Zig struct, send its JSON Schema to an OpenAI-compatible provider, and get a typed value back. Memory for returned values is owned by a session arena.

## Install

Add the package from GitHub:

```sh
zig fetch --save=instructor git+https://github.com/h0rv/instructor.zig.git
```

Then add the module in your `build.zig`:

```zig
const dep = b.dependency("instructor", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("instructor", dep.module("instructor"));
```

This repository is named `instructor.zig`. The Zig package and module name is `instructor`.

## Example

```zig
const std = @import("std");
const instructor = @import("instructor");

const Person = struct {
    name: []const u8,
    age: u8,

    pub const jsonschema = .{
        .name = "Person",
        .description = "Extract person details.",
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var client = instructor.OpenAI.init(.{
        .allocator = gpa,
        .io = init.io,
        .api_key = init.environ_map.get("OPENAI_API_KEY") orelse return error.MissingApiKey,
    });
    defer client.deinit();

    var session = instructor.session(gpa, &client);
    defer session.deinit();

    const person = try session.create(Person, instructor.OpenAI.Request{
        .model = instructor.OpenAI.default_model,
        .messages = &.{.{ .role = .user, .content = "Robby is 24." }},
    }, .{});

    std.debug.print("{s}: {}\n", .{ person.name, person.age });
}
```

Output:

```text
Robby: 24
```

`person` is valid until `session.deinit()` or `session.reset()`.

## API

```zig
pub fn session(allocator: std.mem.Allocator, provider: anytype) Session(Provider);

pub fn Session(comptime Provider: type) type;
```

`Session(Provider)` exposes:

```zig
usage: Usage,
last_usage: Usage,
last_text: ?[]const u8,
last_raw_response: ?[]const u8,

pub fn create(
    self: *Session,
    comptime T: type,
    request: anytype,
    comptime options: Options,
) !T;

pub fn createDetailed(
    self: *Session,
    comptime T: type,
    request: anytype,
    comptime options: Options,
) !CreateResult(T);

pub fn setHooks(self: *Session, hooks: Hooks) void;
pub fn reset(self: *Session) void;
pub fn deinit(self: *Session) void;
```

```zig
pub fn CreateResult(comptime T: type) type {
    return struct {
        value: T,
        text: []const u8,
        raw_response: []const u8,
        usage: Usage,
    };
}
```

```zig
pub const Options = struct {
    mode: Mode = .json_schema,
    max_retries: u8 = 3,
    schema_options: jsonschema.Options = jsonschema.strict_options,
    parse_options: std.json.ParseOptions = .{ .allocate = .alloc_always },
};
```

## Schema options

`instructor.zig` uses `jsonschema.strict_options` by default. Pass comptime `schema_options` to use newer `jsonschema.zig` features such as field naming:

```zig
const user = try session.create(User, req, .{
    .schema_options = comptime blk: {
        var opts = instructor.openai_schema_options;
        opts.field_naming = .camelCase;
        break :blk opts;
    },
});
```

You can inspect the schema sent to providers:

```zig
var schema = try instructor.schemaAlloc(User, gpa, instructor.openai_schema_options);
defer schema.deinit(gpa);
std.debug.print("{s}\n", .{schema.schema_json});
```

## Object roots

Some provider structured-output modes require the root schema to be an object. Wrap root arrays or root unions in a normal Zig struct and use `create` as usual.

For arrays:

```zig
const ActionItem = struct {
    task: []const u8,
    owner: []const u8,
};

const ActionItems = struct {
    items: []const ActionItem,

    pub const jsonschema = .{
        .name = "ActionItems",
        .description = "Extract action items.",
        .fields = .{
            .items = .{ .description = "Action items." },
        },
    };
};

const result = try session.create(ActionItems, req, .{});
for (result.items) |item| {
    std.debug.print("{s}: {s}\n", .{ item.owner, item.task });
}
```

For unions:

```zig
const Next = struct {
    action: Action,
};

const next = try session.create(Next, req, .{});
switch (next.action) {
    .search => |search| ...,
    .finish => |finish| ...,
}
```

This keeps schema shape, provider response shape, and parsed Zig type explicit.

## OpenAI-compatible provider

The provider uses `openai.zig` for the OpenAI HTTP client and generated API surface.

```zig
var client = instructor.OpenAI.init(.{
    .allocator = gpa,
    .io = init.io,
    .api_key = api_key,
    .base_url = "https://api.openai.com/v1",
    .endpoint = .responses,
});
```

`base_url` and `endpoint` can be changed for compatible APIs:

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

Supported endpoints:

| Endpoint | Path | Schema transport |
| --- | --- | --- |
| `.responses` | `/responses` | `text.format` |
| `.chat_completions` | `/chat/completions` | `response_format` |

## Hooks

Hooks observe requests, responses, parse errors, retries, and completions.

```zig
const State = struct {
    fn onEvent(ctx: ?*anyopaque, event: instructor.HookEvent, info: instructor.HookInfo) void {
        _ = ctx;
        std.debug.print("{s} attempt={}\n", .{ @tagName(event), info.attempt });
    }
};

session.setHooks(.{ .on_event = State.onEvent });
```

Events:

```zig
pub const HookEvent = enum {
    request_start,
    response_received,
    parse_error,
    retry,
    completion_done,
};
```

## Modes

Default mode uses provider structured outputs:

```zig
const value = try session.create(T, req, .{});
```

Available modes:

| Mode | Endpoint | Behavior |
| --- | --- | --- |
| `.json_schema` | Responses or Chat Completions | Provider-native structured outputs. |
| `.json_object` | Responses or Chat Completions | JSON mode fallback; parse/retry still applies. |
| `.tool_call` | Chat Completions | Sends `T` as a function tool and parses first tool-call arguments. |
| `.tool_call_required` | Chat Completions | Same, with forced function choice. |
| `.responses_tool_call` | Responses | Sends `T` as a Responses function tool and parses first function-call arguments. |
| `.responses_tool_call_required` | Responses | Same, with forced function choice. |

Messages may include image URLs for multimodal Responses or Chat Completions requests:

```zig
const images = [_]instructor.OpenAI.Image{.{
    .url = "https://example.com/image.jpg",
    .detail = "low",
}};

const value = try session.create(T, .{
    .model = "gpt-5.4-nano",
    .messages = &.{.{
        .role = .user,
        .content = "Inspect this image.",
        .images = &images,
    }},
}, .{});
```

Example:

```zig
const value = try session.create(T, req, .{ .mode = .tool_call });
```

Use required tool modes with OpenAI proper. Some OpenAI-compatible routers reject forced `tool_choice`.

## Diagnostics

Provider errors expose optional status and body.

```zig
const value = session.create(MyType, req, .{}) catch |err| {
    instructor.printError(err, &client);
    return err;
};
```

For custom output:

```zig
try instructor.writeError(writer, err, &client);
```

## Examples

Run examples after exporting API keys:

```sh
set -a; . ./.env; set +a
zig build run-openrouter
zig build run-tool-planner
zig build run-exact-citations
zig build run-action-items
zig build run-agent
zig build run-native-tool-call
zig build run-multimodal-inspection
```

Or use mise tasks. `.mise.toml` loads `.env` for tasks:

```sh
mise run openrouter
mise run planner
mise run citations
mise run actions
mise run agent
mise run tool-call
mise run multimodal
```

Included examples:

- `examples/openrouter.zig` — basic structured extraction.
- `examples/tool_planner.zig` — function-calling-style typed tool planning.
- `examples/exact_citations.zig` — grounded answer with exact quotes.
- `examples/action_items.zig` — meeting transcript to typed action items.
- `examples/agent.zig` — typed agent loop using a native Zig tagged union.
- `examples/native_tool_call.zig` — native Chat Completions tool-call mode.
- `examples/multimodal_inspection.zig` — Responses API image input to typed visual inspection.

## Provider adapter contract

A provider is any type implementing:

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

Optional hooks:

```zig
pub fn deinitRequest(self: *Provider, allocator: std.mem.Allocator, request: *Request) void;
pub fn diagnostic(self: *const Provider) instructor.Diagnostic;
```

`appendRetry` receives borrowed slices. Providers must copy retry data if retaining it after returning.

## Scope

This package orchestrates schema generation, provider calls, parsing, and parse-error retries. It does not validate JSON Schema constraints. Use `jsonschema.zig` for schema generation and a future validator package for value validation.

## Build

```sh
zig build test
zig build examples
```
