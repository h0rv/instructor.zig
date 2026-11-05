# Changelog

## 0.4.0

Added Decisions support for OpenAI and TypeSafe-compatible services. Use `client.decisions.condition` for a boolean branch, or define reusable `Questions(T)` and call `parse` to get a value with automatic response cleanup. Use `parseDetailed` for probabilities and a common OpenAI-shaped response. The exact original provider response is in `raw_response`. The shared `.typesafe` adapter supports Jev through TypeSafe, OpenRouter, or Vercel. Added ticket routing and relevance examples.

## 0.3.0

Added a common `Client` with resource fields `client.responses.create` and `client.responses.parse` for text input. Use `client.messages.create` and `client.messages.parse` for text conversations. Both resources use the configured provider and endpoint through the same adapters. They do not change the HTTP endpoint or provide full native SDK coverage.

Both resources offer `parseWith` with compile-time `ParseOptions`. Applications with a request arena can use `parseInto` or `parseIntoWith`. Owned results have explicit cleanup and can outlive the client. The client accepts an injectable HTTP transport and chooses provider schema defaults internally. Existing low-level provider and `Session` APIs remain available.

The client owns stable heap state. Resource handles borrow that state rather than a pointer to the outer client. They remain valid after moving the client, but must not outlive client cleanup. Do not copy an active client owner.

Added `extra_body`, `extra_headers`, and `extra_query` to request parameters. Client configuration supports deeply copied defaults in `extra_body` and `extra_query`, alongside the existing copied `headers`. JSON objects merge recursively. Request query entries replace defaults by raw name and preserve repeated request names. Query components use RFC 3986 encoding. Request headers override defaults, including authentication and content type, without case-sensitive duplicates. Invalid headers return `error.InvalidHeader`. HTTP owns body framing, so `Content-Length` and `Transfer-Encoding` overrides return `error.ReservedHeader`.

All three HTTP adapters pass extra body fields through for ordinary and typed requests, including existing provider SDK paths. Unknown body keys are not silently dropped. Non-object extras return `error.InvalidExtraBody`. Routing and input fields remain protected with `error.ReservedBodyField`. Typed parsing also protects schema fields while allowing siblings such as `text.verbosity` and `output_config.effort`. `stream: true` or a non-boolean value returns `error.UnsupportedStreaming`. `stream: false` is allowed. Local validation and retries remain in place.

Added a bounded standard-library transport, an adapter for borrowed standard-library clients, and offline examples. Generated SDK files and dependency pins are unchanged. Streaming and Vertex support are not part of this first common API.

## 0.2.0

This release requires Zig 0.17.0. Existing Zig 0.16 users should keep their earlier release pins.

Added a native Anthropic Messages provider for JSON schema output and strict tool extraction. It uses `output_config.format` and native JSON tool inputs. It reports refusals and truncated responses separately from successful structured results. Remote schemas omit unsupported bounds while local validation and retries retain the original constraints.

The Anthropic provider does not support images, recursive schemas, OpenAI Responses tool modes, or generic JSON-object mode. Forced tool selection depends on the selected model. See the README for the schema profile and example.

Updated the OpenAI provider for the regenerated SDK's message unions and format names. Existing Instructor request types remain unchanged. Both providers accept caller-owned allocators and `std.Io` implementations.

Dependencies are pinned to immutable revisions with Zig-generated hashes. CI tests Debug and ReleaseSafe on Linux and macOS. Live provider requests require credentials and are not part of offline CI.
