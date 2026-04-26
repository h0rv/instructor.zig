# instructor.zig

Typed structured-output orchestration for Zig.

Status: early implementation. Session/provider adapter pattern, parse/retry loop, and OpenAI-compatible Responses + Chat Completions adapters are in place.

## Build

```sh
zig build test
```

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
        .base_url = "https://api.openai.com/v1", // override for compatible endpoints
    });
    defer client.deinit();

    var session = instructor.session(gpa, &client);
    defer session.deinit();

    const person = try session.create(Person, instructor.OpenAI.Request{
        .model = instructor.OpenAI.default_model,
        .messages = &.{
            .{ .role = .user, .content = "Robby is 24." },
        },
    }, .{});

    std.debug.print("{s}: {}\n", .{ person.name, person.age });
}
```

Returned `person` is valid until `session.deinit()` or `session.reset()`.

## Diagnostics

Provider errors expose status/body and can be printed without losing the Zig error:

```zig
const person = session.create(Person, req, .{}) catch |err| {
    instructor.printError(err, &client);
    return err;
};
```

## OpenRouter-compatible endpoint

Use Chat Completions endpoint for OpenRouter and many compatible APIs:

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

Run examples after exporting `.env`:

```sh
set -a; . ./.env; set +a
zig build run-openrouter
zig build run-tool-planner
zig build run-exact-citations
zig build run-action-items
```

## Examples

- `examples/openrouter.zig` — basic structured extraction.
- `examples/tool_planner.zig` — function-calling-style typed tool planning.
- `examples/exact_citations.zig` — grounded answer with exact quotes.
- `examples/action_items.zig` — meeting transcript to typed action items.

## Docs

- `docs/api.md` — v0 API and provider adapter contract
- `docs/architecture.md` — file/module boundaries
- `docs/integration-blockers.md` — cross-repo blockers and integration notes

## Validation

V0 intentionally does not do JSON Schema validation. It only generates schema, calls provider, parses JSON into `T`, and retries parse failures.
