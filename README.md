# instructor.zig

A provider-agnostic LLM client with typed extraction for Zig 0.17.0.

Use the same request API for OpenAI Responses, OpenAI-compatible Chat Completions, or Anthropic Messages. Instructor handles provider formats and authentication. You control allocation and result lifetimes.

The common `Client` API is unreleased. The existing `OpenAI`, `Anthropic`, and `Session` APIs remain available.

## Install

For this unreleased API, fetch the feature branch:

```sh
zig fetch --save=instructor git+https://github.com/h0rv/instructor.zig.git#feat/llm-client
```

Pin a commit for reproducible builds. Add the module in `build.zig`:

```zig
const dep = b.dependency("instructor", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("instructor", dep.module("instructor"));
```

## Text and typed extraction

Set `ANTHROPIC_API_KEY` for this example:

```zig
const std = @import("std");
const instructor = @import("instructor");

const Person = struct {
    name: []const u8,
    age: u8,
};

pub fn main(init: std.process.Init) !void {
    var ai = try instructor.Client.fromEnv(init, .{
        .provider = .anthropic,
        .model = "claude-haiku-4-5",
    });
    defer ai.deinit();

    var greeting = try ai.text("Say hello.");
    defer greeting.deinit();

    var person = try ai.extract(Person, .{ .prompt = "Robby is 24." });
    defer person.deinit();

    std.debug.print("{s}\n", .{greeting.text});
    std.debug.print("{s}: {}\n", .{ person.value.name, person.value.age });
}
```

`text` sends an ordinary request without a schema or extraction tools. `extract` generates the schema for `Person`, parses the response, and validates it. Parse and validation failures produce feedback for another attempt. Provider schema defaults are selected automatically.

Both results own their memory. They remain valid after client cleanup if the backing allocator is still alive. Deinitialize each owner once and do not copy an active owner. You can move an owner without invalidating its data.

Run the example with `zig build run-client`. It makes two live requests. To try the API without credentials or network access, run `zig build run-custom-transport`.

## Providers and requests

Use `.provider = .openai` with `OPENAI_API_KEY` for OpenAI Responses. Choose `.endpoint = .chat_completions` and a `base_url` for compatible services. Set a model appropriate to the selected service. Model names are not restricted to a built-in catalog.

`fromEnv` reads the process context you pass in. For servers, use `Client.init` with an explicit allocator and `std.Io`. Credentials can come from your own configuration:

```zig
var ai = try instructor.Client.init(.{
    .allocator = allocator,
    .io = io,
    .provider = .{
        .openai = .{
            .api_key = api_key,
            .base_url = "https://openrouter.ai/api/v1",
            .endpoint = .chat_completions,
        },
    },
    .model = "your-model",
});
defer ai.deinit();
```

Client configuration strings and additional `headers` are copied. Request inputs are borrowed only until the call returns.

For a conversation, use `complete`. A supplied `prompt` becomes a user message after the history:

```zig
var reply = try ai.complete(.{
    .messages = &.{
        .{
            .role = .system,
            .content = "Answer briefly.",
        },
    },
    .prompt = "What is an arena allocator?",
    .max_output_tokens = 256,
});
defer reply.deinit();
```

Requests can override `model`. OpenAI requests also support `temperature`. The current Anthropic adapter rejects that control instead of silently ignoring it.

## Bring your own HTTP client

Pass a borrowed `http.Transport` to `Client.init` or `Client.fromEnv`. Its callback receives the URL and headers with the request body. It returns an owned HTTP response. Instructor never closes the injected context.

An existing standard-library client has a ready-made adapter:

```zig
.transport = instructor.http.Transport.fromStd(&http_client),
```

Other HTTP clients implement the same small callback. See [the transport contract](docs/transport.md) and [the runnable offline example](examples/custom_transport.zig).

Without an injected transport, Instructor owns a pooled standard-library client. It keeps TLS verification enabled and does not follow redirects. The default response limit is 8 MiB, applied after decompression to success and error bodies. Set `max_response_bytes` to change it.

## Control memory and extraction

If your application already has a request arena, put results there:

```zig
const person = try ai.extractInto(Person, arena.allocator(), .{
    .prompt = "Robby is 24.",
});
```

Here, `person` is a `Person` value and remains valid until you release the arena. There is no per-result `deinit`.

Use `extractWith` or `extractIntoWith` for compile-time extraction settings:

```zig
var person = try ai.extractWith(Person, .{ .prompt = "Robby is 24." }, .{
    .max_retries = 1,
});
defer person.deinit();
```

Results include text and raw response data alongside token usage. Use `instructor.printError(err, &ai)` to inspect provider diagnostics after a failure.

## Scope

The common client currently supports buffered text completion and structured extraction. It does not yet expose streaming, general tool conversations, multimodal messages, or Vertex routing. Calls on one client are synchronous and must not run concurrently.

The existing lower-level provider and `Session` APIs remain available for their supported extraction modes and image inputs. See [the API reference](docs/api.md), [existing examples](examples), and [the new client guide](docs/client.md).

Generated SDK files and dependency pins are unchanged. Instructor adapters use the generated SDKs without requiring handwritten changes to them.

## Build

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build docs
```
