# instructor.zig

[![Zig Version](https://img.shields.io/badge/zig-0.16.0%2B-orange.svg)](https://ziglang.org/download/)

Typed structured outputs for Zig.

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
pub fn create(
    self: *Session,
    comptime T: type,
    request: anytype,
    comptime options: Options,
) !T;

pub fn reset(self: *Session) void;
pub fn deinit(self: *Session) void;
```

```zig
pub const Options = struct {
    mode: Mode = .json_schema,
    max_retries: u8 = 3,
    schema_options: jsonschema.Options = jsonschema.openai_strict_options,
    parse_options: std.json.ParseOptions = .{ .allocate = .alloc_always },
};
```

## OpenAI-compatible provider

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
```

Included examples:

- `examples/openrouter.zig` — basic structured extraction.
- `examples/tool_planner.zig` — function-calling-style typed tool planning.
- `examples/exact_citations.zig` — grounded answer with exact quotes.
- `examples/action_items.zig` — meeting transcript to typed action items.

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
