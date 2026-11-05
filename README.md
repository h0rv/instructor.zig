# instructor.zig

Get structured data from LLMs as Zig types. This library requires Zig 0.17.0.

Define a struct and call `parse`. Instructor generates its JSON Schema and validates the result. If parsing or validation fails, Instructor sends error feedback to the model and retries.

Use the same `client.responses.parse` or `client.messages.parse` calls with OpenAI Responses, OpenAI-compatible Chat Completions, or Anthropic Messages. Choose the provider and endpoint in client configuration.

Use `client.decisions` with OpenAI or TypeSafe-compatible services for boolean conditions and typed routing.

## Install

Add the dependency:

```sh
zig fetch --save=instructor 'git+https://github.com/h0rv/instructor.zig.git?ref=v0.3.0'
```

Pin a commit for reproducible builds. Add the module in `build.zig`:

```zig
const dep = b.dependency("instructor", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("instructor", dep.module("instructor"));
```

## Extract a product

Set `ANTHROPIC_API_KEY` for this example:

```zig
const std = @import("std");
const instructor = @import("instructor");

const Product = struct {
    name: []const u8,
    price: f64,
    in_stock: bool,
};

pub fn main(init: std.process.Init) !void {
    var ai = try instructor.Client.fromEnv(init, .{
        .provider = .anthropic,
        .model = "claude-haiku-4-5",
    });
    defer ai.deinit();

    var product = try ai.responses.parse(Product, .{
        .input = "Extract the product: Coffee mug costs $12.50 and is in stock.",
    });
    defer product.deinit();

    std.debug.print("{s}: {d:.2}, in stock={}\n", .{
        product.value.name,
        product.value.price,
        product.value.in_stock,
    });
}
```

Expected output:

```text
Coffee mug: 12.50, in stock=true
```

The result owns its memory. It remains valid after client cleanup if the backing allocator is still alive. Deinitialize each owner once and do not copy an active owner.

Run [this example](examples/client.zig) with `zig build run-client`. It makes a live request and may retry. To try the same extraction without credentials or network access, run `zig build run-custom-transport`.

## Decisions API

Ask a fixed question about text and use the answer in an ordinary Zig branch:

```zig
var client = try instructor.Client.fromEnv(init, .{
    .provider = .openai,
    .model = "gpt-6-luna",
});
defer client.deinit();

if (try client.decisions.condition(.{
    .input = passage,
    .instructions = "Does this passage answer the search query?",
    .threshold = 0.8,
})) {
    includePassage();
} else {
    omitPassage();
}
```

For several answers, define `Questions(T)` once and call `questions.parse(...)`. It returns the value and handles response cleanup. Use `parseDetailed(...)` when you need probabilities.

For Jev through TypeSafe, OpenRouter, or Vercel, use the shared `.typesafe` adapter. The `condition` and `Questions(T)` calls stay the same. See [provider configuration](docs/decisions.md#provider-configuration) and the [ticket routing example](examples/decisions.zig).

## What you can build

| Feature | Example or guide |
| --- | --- |
| Generate schemas from Zig types. | [Product extraction](examples/client.zig). |
| Validate field constraints and retry with error feedback. | [Name and age constraints](examples/openrouter.zig) and [retry options](docs/client.md#parsing-options-and-retries). |
| Extract nested objects and arrays. | [Invoice with line items](examples/invoice_extraction.zig). |
| Process reviews one at a time and free each result. | [Batch extraction](examples/batch_extract.zig) with `Session.reset()`. |
| Classify text into typed cases. | [Tagged union classification](examples/classify_union.zig) and [support routing](examples/support_router.zig). |
| Use model decisions in `if` and `switch`. | [Decisions guide](docs/decisions.md) and [ticket routing](examples/decisions.zig). |
| Request answers with supporting quotes. | [Exact citations](examples/exact_citations.zig). Check quotes against the source before trusting them. |
| Extract tasks or propose redactions. | [Meeting actions](examples/action_items.zig) and [PII redaction](examples/pii_redaction.zig). Review redactions before logging sensitive text. |
| Observe requests and retries. | [Hooks and usage](docs/api.md#hooks). |
| Use your own HTTP client. | [Offline custom transport](examples/custom_transport.zig). |

Most advanced examples use `Session`, not the common client.

## Providers and requests

With `Client.fromEnv`, use `.provider = .openai` and set `OPENAI_API_KEY` for OpenAI Responses. Choose `.endpoint = .chat_completions` and a `base_url` for compatible services. Set a model appropriate to the selected service. Model names are not restricted to a built-in catalog.

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

Client configuration strings and default `headers` are copied. Client defaults in `extra_body` and `extra_query` are deeply copied during initialization. Request values are borrowed only until the call returns.

For ordinary text without an output schema, use `create`. For a conversation, use `messages`. Both resources have `create` and `parse` methods:

```zig
var reply = try ai.messages.create(.{
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
```

`responses` currently accepts only text in `input`. Its token limit is `max_output_tokens`. The resource fields borrow stable heap state and remain valid when you move the outer client. They must not outlive `client.deinit()`. Do not copy an active client owner.

Requests can override `model`. OpenAI requests also support `temperature`. The current Anthropic adapter rejects that control instead of silently ignoring it.

For provider fields beyond the typed parameters, use `extra_body`, `extra_headers`, or `extra_query` on either resource. See [request extras](docs/client.md#request-extras) for merge rules and protected fields.

## Bring your own HTTP client

Pass a borrowed `http.Transport` to `Client.init` or `Client.fromEnv`. Its callback receives the URL and headers with the request body. It returns an owned HTTP response. Instructor never closes the injected context.

An existing standard-library client has a ready-made adapter:

```zig
.transport = instructor.http.Transport.fromStd(&http_client),
```

Other HTTP clients implement the same small callback. See [the transport contract](docs/transport.md) and [the runnable offline example](examples/custom_transport.zig).

Without an injected transport, Instructor owns a pooled standard-library client. It keeps TLS verification enabled and does not follow redirects. The default response limit is 8 MiB, applied after decompression to success and error bodies. Set `max_response_bytes` to change it.

## Control memory and parsing

If your application already has a request arena, put results there:

```zig
const product = try ai.responses.parseInto(Product, arena.allocator(), .{
    .input = "Extract the product: Coffee mug costs $12.50 and is in stock.",
});
```

Here, `product` is a `Product` value and remains valid until you release the arena. There is no per-result `deinit`.

Use `parseWith` or `parseIntoWith` with compile-time `ParseOptions`:

```zig
var product = try ai.responses.parseWith(Product, .{
    .input = "Extract the product: Coffee mug costs $12.50 and is in stock.",
}, .{ .max_retries = 1 });
defer product.deinit();
```

Results include text and raw response data alongside token usage. Use `instructor.printError(err, &ai)` to inspect provider diagnostics after a failure.

## Scope

The common client supports buffered text responses and typed parsing. It does not provide full native SDK coverage. There is no streaming or async API. Partial structured results, general tool conversations, multimodal input, and Vertex routing are not supported. Do not run calls concurrently on one client.

Use the provider and `Session` APIs for additional extraction modes and image inputs. See [the API reference](docs/api.md), [examples](examples), and [client guide](docs/client.md).

## Build

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build docs
```
