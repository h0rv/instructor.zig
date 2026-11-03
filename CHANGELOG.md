# Changelog

## Unreleased

Added a common `Client` for buffered text completion and typed extraction across the existing providers. It accepts an injectable HTTP transport and chooses provider schema defaults internally. Owned results have explicit cleanup and can outlive the client. Applications with a request arena can use `extractInto` instead.

Added a bounded standard-library transport, an adapter for borrowed standard-library clients, and offline examples. Generated SDK files and dependency pins are unchanged. Streaming and Vertex support are not part of this first common API.

## 0.2.0

This release requires Zig 0.17.0. Existing Zig 0.16 users should keep their earlier release pins.

Added a native Anthropic Messages provider for JSON schema output and strict tool extraction. It uses `output_config.format` and native JSON tool inputs. It reports refusals and truncated responses separately from successful structured results. Remote schemas omit unsupported bounds while local validation and retries retain the original constraints.

The Anthropic provider does not support images, recursive schemas, OpenAI Responses tool modes, or generic JSON-object mode. Forced tool selection depends on the selected model. See the README for the schema profile and example.

Updated the OpenAI provider for the regenerated SDK's message unions and format names. Existing Instructor request types remain unchanged. Both providers accept caller-owned allocators and `std.Io` implementations.

Dependencies are pinned to immutable revisions with Zig-generated hashes. CI tests Debug and ReleaseSafe on Linux and macOS. Live provider requests require credentials and are not part of offline CI.
