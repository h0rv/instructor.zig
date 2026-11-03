# Common LLM client

`Client` is an additive API over the existing provider adapters. Use one client for a sequence of synchronous calls. Requests use the same `Request` and `Message` types across OpenAI Responses, Chat Completions, and Anthropic Messages.

The provider is chosen explicitly. Instructor does not guess credentials or routing from model names. OpenAI-compatible services use the OpenAI adapter with a custom base URL and endpoint.

## Operations

| Method | Result | Purpose |
| --- | --- | --- |
| `text(prompt)` | `Response` | One ordinary user prompt. |
| `complete(request)` | `Response` | Ordinary text with conversation history and controls. |
| `extract(T, request)` | `Owned(T)` | Typed structured extraction with default validation and retries. |
| `extractWith(T, request, options)` | `Owned(T)` | Extraction with compile-time settings. |
| `extractInto(T, allocator, request)` | `T` | Extraction into caller-owned arena memory. |
| `extractIntoWith(T, allocator, request, options)` | `T` | Caller-owned extraction with compile-time settings. |

`Response` has `text`, `raw_response`, `usage`, `provider`, and `model`. `Owned(T)` also has `value`. Both own an arena and have parameterless `deinit` methods. Their allocators have stable contexts, including when custom JSON parsers retain the allocator passed to them.

`extractInto` and `extractIntoWith` return `T` directly and do not create result owners. Use a result arena, then free that arena as a group. Successful results retain copied text, including with `.allocate = .alloc_if_needed`.

## Memory rules

- Client configuration strings and headers are copied.
- Credentials can be provided through `Client.init` without environment access.
- `Client.fromEnv` reads only the supplied process context.
- Message and prompt inputs remain borrowed during the call.
- Results are independent of client lifetime, but their backing allocator must stay alive.
- Deinitialize an owner exactly once. Do not copy active owners.
- Injected transport contexts and I/O implementations remain caller-owned.

The default HTTP client owns its pool. Its state has a stable heap address so moving the outer client does not invalidate pool references. A custom transport can share its own pool across several Instructor clients.

## Requests

A request may contain messages, a prompt, or both. When both are supplied, the prompt is appended as a user message. An input with neither returns `MissingInput`.

A request model overrides the client default. Model names are forwarded without a built-in catalog check. The selected model must support the requested feature.

The common API accepts text messages with `system`, `user`, and `assistant` roles. `max_output_tokens` maps to the provider's output-token setting. A value of zero is rejected. OpenAI temperature must be finite and between zero and two. Anthropic temperature returns `UnsupportedControl`.

Ordinary completion sends no output schema or extraction tools. It concatenates text blocks and preserves the raw response. Explicit refusals and incomplete output are errors rather than successful partial text. Tool-call arguments are not returned as ordinary text.

## Extraction

The common client reuses `createDetailedWithArena`. Schema generation and local validation remain in the existing core. Failed parsing or validation adds feedback through the existing provider retry methods. Usage covers every extraction attempt.

`ExtractionOptions` provides `mode`, `max_retries`, `validate`, optional `schema_options`, and `parse_options`. These options are compile-time values. The default permits three retries after the first attempt. Transport failures are returned immediately rather than retried as validation failures.

If `schema_options` is omitted, Instructor chooses the provider profile. Anthropic remote schemas omit unsupported bounds while core validation retains explicit constraints. Recursive and unsupported schemas still return explicit errors.

Hooks use the existing event types. A configured hook context is borrowed and must outlive calls. Do not destroy or reenter the client from a hook.

## Compatibility and limits

The generated SDKs are unchanged. Existing `OpenAI`, `Anthropic`, `Session`, and low-level extraction functions remain available.

Low-level providers keep their existing SDK dispatch when no transport is supplied. Their response limit applies to injected transports. The common client always uses a bounded transport, including when it creates the default implementation.

This first common API covers buffered text completion and typed extraction. It does not claim streaming, arbitrary tool conversations, multimodal message normalization, dynamic provider registration, or Vertex support. Those features need explicit contracts rather than silent fallbacks.
