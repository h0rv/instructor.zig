# Common LLM client

`Client` provides buffered text responses and typed parsing through the existing provider adapters. Choose the provider and endpoint when you configure the client. Model names do not select credentials or routing.

Use `client.responses` for text input or `client.messages` for conversations. These are resource fields, not methods. Both use the same internal adapters and configured HTTP endpoint. `client.responses` on an Anthropic client still uses Anthropic Messages. `client.messages` on an OpenAI Responses client still uses OpenAI Responses.

The client owns state at a stable heap address. Resource handles borrow that state, not a pointer to the outer client. You can move the outer client without invalidating its handles. Handles must not outlive `client.deinit()`. Do not copy an active client owner. Calls on one client are synchronous and must not run concurrently.

## Create and parse

Use `create` for ordinary output and `parse` for a typed result:

```zig
var greeting = try client.responses.create(.{ .input = "Say hello." });
defer greeting.deinit();

var person = try client.responses.parse(Person, .{ .input = "Robby is 24." });
defer person.deinit();
```

These names follow the official SDK conventions for [OpenAI Responses parsing](https://github.com/openai/openai-python/blob/main/helpers.md#parsing-responses-api-output) and [Anthropic Messages parsing](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/resources/messages/messages.py). The common client exposes typed fields for common controls. Use request extras for other provider fields. This is not full native SDK coverage.

Both resources have the same methods. Here, `params` means the parameters for the selected resource:

| Method | Result | Purpose |
| --- | --- | --- |
| `create(params)` | `Response` | Ordinary text without an output schema. |
| `parse(T, params)` | `Owned(T)` | Typed parsing with default validation and retries. |
| `parseWith(T, params, options)` | `Owned(T)` | Typed parsing with compile-time `ParseOptions`. |
| `parseInto(T, allocator, params)` | `T` | Typed parsing into caller-owned arena memory. |
| `parseIntoWith(T, allocator, params, options)` | `T` | Caller-owned parsing with compile-time `ParseOptions`. |

`Response` has `text`, `raw_response`, `usage`, `provider`, and `model`. `Owned(T)` also has `value`. Both own an arena and have parameterless `deinit` methods. Their allocators have stable contexts, including when custom JSON parsers retain the allocator passed to them.

`create` does not generate an output schema or extraction tools. It concatenates text blocks and preserves the raw response. Explicit refusals and incomplete output are errors rather than successful partial text. Tool-call arguments are not returned as ordinary text.

## Parameters

### Responses resource

`client.responses` accepts `ResponseCreateParams` with a required text `input`. It does not yet accept arrays of input items or multimodal input.

| Field | Type | Default |
| --- | --- | --- |
| `input` | `[]const u8` | Required. |
| `model` | `?[]const u8` | `null` uses the client model. |
| `max_output_tokens` | `?u32` | `null`. |
| `temperature` | `?f64` | `null`. |
| `extra_body` | `?std.json.Value` | `null`. |
| `extra_headers` | `[]const std.http.Header` | `&.{}`. |
| `extra_query` | `[]const instructor.QueryParam` | `&.{}`. |

### Messages resource

`client.messages` accepts `MessageCreateParams` with a required slice of `Message` values. Each message has a text `content` and a `system`, `user`, or `assistant` role.

```zig
var reply = try client.messages.create(.{
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

var person = try client.messages.parse(Person, .{
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

| Field | Type | Default |
| --- | --- | --- |
| `messages` | `[]const Message` | Required. |
| `model` | `?[]const u8` | `null` uses the client model. |
| `max_tokens` | `?u32` | `null`. |
| `temperature` | `?f64` | `null`. |
| `extra_body` | `?std.json.Value` | `null`. |
| `extra_headers` | `[]const std.http.Header` | `&.{}`. |
| `extra_query` | `[]const instructor.QueryParam` | `&.{}`. |

Both resources use the selected provider's output-token setting. A token limit of zero is rejected. Model names are forwarded without a built-in catalog check. The selected model must support the requested feature. OpenAI temperature must be finite and between zero and two. Anthropic temperature returns `UnsupportedControl`.

## Request extras

Use `extra_body` for JSON fields not represented by typed parameters. Use `extra_headers` for HTTP headers and `extra_query` for URL query parameters. These fields work with ordinary `create` calls and every typed parsing method on both resources.

`ClientConfig` and `EnvConfig` accept `extra_body: ?std.json.Value = null` and `extra_query: []const instructor.QueryParam = &.{}` as defaults. The existing `headers: []const std.http.Header = &.{}` field supplies default headers. Initialization deeply copies these defaults, including JSON strings and nested values. Per-request extras are borrowed only until the call returns.

Parse a JSON literal with `std.json.parseFromSlice` to build a `std.json.Value`. This example assumes `std`, `instructor`, and application values for `allocator`, `io`, and `api_key` are in scope:

```zig
const defaults = try std.json.parseFromSlice(std.json.Value, allocator,
    \\{"metadata":{"source":"example"}}
, .{});
defer defaults.deinit();

const default_headers = [_]std.http.Header{
    .{ .name = "X-Request-Id", .value = "default" },
};
const default_query = [_]instructor.QueryParam{
    .{ .name = "tag", .value = "default" },
};

var client = try instructor.Client.init(.{
    .allocator = allocator,
    .io = io,
    .provider = .{
        .openai = .{
            .api_key = api_key,
        },
    },
    .model = "your-model",
    .headers = &default_headers,
    .extra_body = defaults.value,
    .extra_query = &default_query,
});
defer client.deinit();
```

The following request adds a nested body field and overrides the header and query defaults. It is an explanatory example, not a live-call recipe. Use only fields and query parameters accepted by your selected endpoint and model.

```zig
const extra = try std.json.parseFromSlice(std.json.Value, allocator,
    \\{"text":{"verbosity":"low"},"metadata":{"request":"one"}}
, .{});
defer extra.deinit();

const request_headers = [_]std.http.Header{
    .{ .name = "X-Request-Id", .value = "example-1" },
};
const request_query = [_]instructor.QueryParam{
    .{ .name = "tag", .value = "one & two" },
    .{ .name = "tag", .value = "three" },
};

var person = try client.responses.parse(Person, .{
    .input = "Robby is 24.",
    .extra_body = extra.value,
    .extra_headers = &request_headers,
    .extra_query = &request_query,
});
defer person.deinit();
```

### Merge and validation rules

Body objects merge recursively. Client defaults apply first, then request extras. Request scalars and arrays replace existing values rather than being appended. In the example, `metadata.source` remains and `metadata.request` is added. Unknown body keys are passed through, not silently dropped. The provider may still reject them. A non-object `extra_body`, including a JSON `null`, returns `error.InvalidExtraBody`. Use Zig `null` to omit extras.

Use typed parameters to set `model`, `input`, and `messages`. Those top-level fields are reserved in extras and return `error.ReservedBodyField`, even if the supplied value matches the typed value.

Typed parsing also protects the selected API’s schema fields:

- OpenAI Responses: `text.format`.
- Chat Completions: `response_format`.
- Anthropic Messages: `output_config.format`.
- All three APIs: `tools` and `tool_choice`.

Overriding one of these fields returns `error.ReservedBodyField`. Replacing a parent such as `text` with a scalar or array is also rejected. Sibling fields such as `text.verbosity` and `output_config.effort` are allowed. These schema restrictions apply to parsing, not ordinary `create` calls. Local validation and retries remain enabled unless changed through parsing options.

Only buffered responses are supported. An extra `stream` field set to `true` or any non-boolean value returns `error.UnsupportedStreaming`. `stream: false` is allowed.

`QueryParam` has `name: []const u8` and `value: []const u8`. Request entries replace all client defaults with the same raw name. Repeated names in the request are preserved. Names are compared before encoding. Each name and value is encoded as a separate RFC 3986 component. Pass raw strings, not encoded strings or query fragments. The example sends `tag=one%20%26%20two&tag=three` without the default `tag` entry.

Request headers override client defaults and generated headers case-insensitively, including authentication and content type. Each header name is sent once. If a name repeats in one list, the last value wins. Header names and values are validated. Invalid names or control characters return `error.InvalidHeader`. Body framing is managed by HTTP: `Content-Length` and `Transfer-Encoding` overrides return `error.ReservedHeader`. Be careful when replacing credentials or content type.

The OpenAI Responses, OpenAI-compatible Chat Completions, and Anthropic Messages adapters apply these rules. Extra fields also pass through the existing low-level provider SDK paths. Generated SDK files and dependency pins are unchanged.

## Memory rules

- Client configuration strings and default headers are copied. Default JSON bodies and query parameters are deeply copied.
- Credentials can be provided through `Client.init` without environment access.
- `Client.fromEnv` reads only the supplied process context.
- Request input, messages, and extras remain borrowed until the call returns.
- Resource handles remain valid across moves of the client, but not after client cleanup.
- Results are independent of client lifetime, but their backing allocator must stay alive.
- Deinitialize an owner exactly once. Do not copy active owners.
- Injected transport contexts and I/O implementations remain caller-owned.

The default HTTP client owns its pool in stable heap storage. A custom transport can share its own pool across several Instructor clients. See [the transport contract](transport.md).

`parseInto` and `parseIntoWith` return `T` directly without a result owner:

```zig
const person = try client.responses.parseInto(Person, arena.allocator(), .{
    .input = "Robby is 24.",
});
```

Use a result arena, then free that arena as a group. There is no per-result `deinit`. Successful results retain copied text, including with `.allocate = .alloc_if_needed`.

## Parsing options and retries

The common client reuses `createDetailedWithArena`. Schema generation and local validation remain in the existing core. Failed parsing or validation adds feedback through the existing provider retry methods. Usage covers every parsing attempt.

`ParseOptions` provides `mode`, `max_retries`, `validate`, optional `schema_options`, and `parse_options`. These options are compile-time values. The default permits three retries after the first attempt. Transport failures are returned immediately rather than retried as validation failures.

```zig
var person = try client.responses.parseWith(Person, .{ .input = "Robby is 24." }, .{
    .max_retries = 1,
});
defer person.deinit();

const arena_person = try client.responses.parseIntoWith(Person, arena.allocator(), .{
    .input = "Robby is 24.",
}, .{ .max_retries = 1 });
```

The same methods work on `client.messages` with its message parameters.

If `schema_options` is omitted, Instructor chooses the provider profile. Anthropic remote schemas omit unsupported bounds while core validation retains explicit constraints. Recursive and unsupported schemas still return explicit errors.

Hooks use the existing event types. A configured hook context is borrowed and must outlive calls. Do not destroy or reenter the client from a hook.

## Compatibility and limits

The generated SDKs are unchanged. Existing `OpenAI`, `Anthropic`, `Session`, and low-level extraction functions remain available with their existing names.

Low-level providers keep their existing SDK dispatch when no transport is supplied. Request extras are applied on those paths too. Their response limit applies to injected transports. The common client always uses a bounded transport, including when it creates the default implementation.

This common API supports buffered text only. It does not support streaming, arbitrary tool conversations, multimodal input, dynamic provider registration, or Vertex routing. The Responses resource currently accepts only text input. The Messages resource accepts text conversations. Neither resource provides full native SDK coverage.
