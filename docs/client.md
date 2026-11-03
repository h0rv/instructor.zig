# Common LLM client

`Client` provides buffered text responses and typed parsing through the existing provider adapters. Choose the provider and endpoint when you configure the client. Model names do not select credentials or routing.

Use `client.responses()` for text input or `client.messages()` for conversations. Both views use the same internal adapters and configured HTTP endpoint. Calling `responses()` on an Anthropic client still uses Anthropic Messages. Calling `messages()` on an OpenAI Responses client still uses OpenAI Responses.

Each call to `responses()` or `messages()` creates a borrowed resource handle. The parentheses are intentional. The client does not store a pointer to itself. Keep the client alive and at the same address while a handle is in use. Calls on one client are synchronous and must not run concurrently.

## Create and parse

Use `create` for ordinary output and `parse` for a typed result:

```zig
var greeting = try client.responses().create(.{ .input = "Say hello." });
defer greeting.deinit();

var person = try client.responses().parse(Person, .{ .input = "Robby is 24." });
defer person.deinit();
```

These names follow the official SDK conventions for [OpenAI Responses parsing](https://github.com/openai/openai-python/blob/main/helpers.md#parsing-responses-api-output) and [Anthropic Messages parsing](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/resources/messages/messages.py). The common client supports only the fields described below, not the full native SDK APIs.

Both views have the same methods. Here, `params` means the parameters for the selected view:

| Method | Result | Purpose |
| --- | --- | --- |
| `create(params)` | `Response` | Ordinary text without an output schema. |
| `parse(T, params)` | `Owned(T)` | Typed parsing with default validation and retries. |
| `parseWith(T, params, options)` | `Owned(T)` | Typed parsing with compile-time `ParseOptions`. |
| `parseInto(T, allocator, params)` | `T` | Typed parsing into caller-owned arena memory. |
| `parseIntoWith(T, allocator, params, options)` | `T` | Caller-owned parsing with compile-time `ParseOptions`. |

`Response` has `text`, `raw_response`, `usage`, `provider`, and `model`. `Owned(T)` also has `value`. Both own an arena and have parameterless `deinit` methods. Their allocators have stable contexts, including when custom JSON parsers retain the allocator passed to them.

`create` sends no output schema or extraction tools. It concatenates text blocks and preserves the raw response. Explicit refusals and incomplete output are errors rather than successful partial text. Tool-call arguments are not returned as ordinary text.

## Parameters

### Responses view

`responses()` accepts a required text `input`. It does not yet accept arrays of input items or multimodal input.

| Field | Type | Requirement |
| --- | --- | --- |
| `input` | `[]const u8` | Required. |
| `model` | `?[]const u8` | Optional model override. |
| `max_output_tokens` | `?u32` | Optional output-token limit. |
| `temperature` | `?f64` | Optional temperature. |

### Messages view

`messages()` accepts a required slice of `Message` values. Each message has a text `content` and a `system`, `user`, or `assistant` role.

```zig
var reply = try client.messages().create(.{
    .messages = &.{
        .{
            .role = .system,
            .content = "Answer briefly.",
        },
        .{
            .role = .user,
            .content = "What is an arena allocator?",
        },
    },
    .max_tokens = 256,
});
defer reply.deinit();

var person = try client.messages().parse(Person, .{
    .messages = &.{
        .{
            .role = .user,
            .content = "Robby is 24.",
        },
    },
    .max_tokens = 256,
});
defer person.deinit();
```

| Field | Type | Requirement |
| --- | --- | --- |
| `messages` | `[]const Message` | Required. |
| `model` | `?[]const u8` | Optional model override. |
| `max_tokens` | `?u32` | Optional output-token limit. |
| `temperature` | `?f64` | Optional temperature. |

Both views use the selected provider's output-token setting. A token limit of zero is rejected. Model names are forwarded without a built-in catalog check. The selected model must support the requested feature. OpenAI temperature must be finite and between zero and two. Anthropic temperature returns `UnsupportedControl`.

## Memory rules

- Client configuration strings and headers are copied.
- Credentials can be provided through `Client.init` without environment access.
- `Client.fromEnv` reads only the supplied process context.
- Request input and messages remain borrowed until the call returns.
- Results are independent of client lifetime, but their backing allocator must stay alive.
- Deinitialize an owner exactly once. Do not copy active owners.
- Injected transport contexts and I/O implementations remain caller-owned.

The default HTTP client owns its pool. Its state has a stable heap address so moving the outer client does not invalidate pool references. A custom transport can share its own pool across several Instructor clients. See [the transport contract](transport.md).

`parseInto` and `parseIntoWith` return `T` directly without a result owner:

```zig
const person = try client.responses().parseInto(Person, arena.allocator(), .{
    .input = "Robby is 24.",
});
```

Use a result arena, then free that arena as a group. There is no per-result `deinit`. Successful results retain copied text, including with `.allocate = .alloc_if_needed`.

## Parsing options and retries

The common client reuses `createDetailedWithArena`. Schema generation and local validation remain in the existing core. Failed parsing or validation adds feedback through the existing provider retry methods. Usage covers every parsing attempt.

`ParseOptions` provides `mode`, `max_retries`, `validate`, optional `schema_options`, and `parse_options`. These options are compile-time values. The default permits three retries after the first attempt. Transport failures are returned immediately rather than retried as validation failures.

```zig
var person = try client.responses().parseWith(Person, .{ .input = "Robby is 24." }, .{
    .max_retries = 1,
});
defer person.deinit();

const arena_person = try client.responses().parseIntoWith(Person, arena.allocator(), .{
    .input = "Robby is 24.",
}, .{ .max_retries = 1 });
```

The same methods work on `messages()` with its message parameters.

If `schema_options` is omitted, Instructor chooses the provider profile. Anthropic remote schemas omit unsupported bounds while core validation retains explicit constraints. Recursive and unsupported schemas still return explicit errors.

Hooks use the existing event types. A configured hook context is borrowed and must outlive calls. Do not destroy or reenter the client from a hook.

## Compatibility and limits

The generated SDKs are unchanged. Existing `OpenAI`, `Anthropic`, `Session`, and low-level extraction functions remain available with their existing names.

Low-level providers keep their existing SDK dispatch when no transport is supplied. Their response limit applies to injected transports. The common client always uses a bounded transport, including when it creates the default implementation.

This common API supports buffered text only. It does not support streaming, arbitrary tool conversations, multimodal input, dynamic provider registration, or Vertex routing. The Responses view currently accepts only text input. The Messages view accepts text conversations. Neither view provides full native SDK coverage.
