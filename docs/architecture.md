# Code architecture

Target: small core, provider adapters at edges.

## File layout

```text
src/
  root.zig                 public package exports

  core/
    mod.zig                core re-exports + tests
    types.zig              shared public structs: Usage, Completion, StructuredSchema, Hooks
    options.zig            Options + schema profile defaults
    session.zig            Session arena owner + session() helper
    create.zig             createWithArena/createDetailedWithArena parse/retry loop
    util.zig               tiny comptime helpers

  providers/
    mod.zig                provider re-exports
    openai.zig             OpenAI-compatible provider adapter backed by openai.zig SDK
    testing.zig            fake provider for core tests/examples
```

## Boundaries

### Core owns orchestration

Core does:

- build schema for `T`
- call provider
- parse JSON into caller/session arena
- retry parse failures
- accumulate usage
- emit hooks
- retain per-call text/raw response for detailed results

Core does not:

- know provider request internals
- validate JSON Schema constraints
- own HTTP details
- store provider-specific data

### Session owns result lifetime

`Session` owns arena for returned values. `session.create(T, req, .{})` returns `T` directly. `session.createDetailed(T, req, .{})` returns value plus response text, raw response, and per-call usage. Returned values and detailed response slices die at `session.deinit()` or `session.reset()`.

### Provider owns transport + retry mutation

Provider adapter implements:

```zig
completeStructured(...)
appendRetry(...)
```

Provider decides:

- HTTP endpoint
- auth headers through openai.zig
- OpenAI-compatible URL override
- request JSON shape
- output text extraction
- provider error diagnostics
- retry message append format

`appendRetry` receives borrowed slices. Provider adapters must copy retry data if they retain it after returning.

Providers may expose diagnostics with:

```zig
pub fn diagnostic(self: *const Provider) instructor.Diagnostic;
```

Core helpers `instructor.writeError(writer, err, provider)` and `instructor.printError(err, provider)` print provider status/body when available.

## Public imports

Users should import only package root:

```zig
const instructor = @import("instructor");
```

Then use:

```zig
var client = instructor.OpenAI.init(...);
var session = instructor.session(gpa, &client);
const value = try session.create(MyType, req, .{});
```

Internal modules stay available for maintainers but not needed by app users.
