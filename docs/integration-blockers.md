# Integration notes

Target Zig version: `0.16.0`.

## Resolved for current scaffold

- `jsonschema.zig` is now consumed from `github.com/h0rv/jsonschema.zig` with a pinned commit and package hash.
- `jsonschema` options are comptime and `openai_strict_options` is used by default.
- `instructor.zig` builds as a library and compiles examples during `zig build test`.
- Primary API returns `T` directly through a session-owned arena.
- OpenAI-compatible provider supports both Responses and Chat Completions endpoints.
- OpenRouter can be used with `.base_url = "https://openrouter.ai/api/v1"` and `.endpoint = .chat_completions`.

## Deferred

- JSON Schema validation: keep out of core; integrate `validate.zig` or another validator later.
- Native provider tool-call mode: current examples use structured outputs as typed tool planning.
- Union/discriminator extraction for agent loops.
- Streaming partial-object parsing.
- Multimodal request parts.
- Rich error result type; current provider exposes `lastStatus()` and `lastErrorBody()` for diagnostics.

## Provider contract reminders

- `completeStructured` returns owned `Completion.text` and `Completion.raw_response` allocated with the provided allocator.
- `appendRetry` receives borrowed slices. Providers must copy retry data if retaining it after the function returns.
- `deinitRequest`, when present, must release retry-owned request data.
