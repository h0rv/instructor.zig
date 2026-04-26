# Code architecture

Target: small core, provider adapters at edges.

## File layout

```text
src/
  root.zig                 public package exports

  core/
    mod.zig                core re-exports + tests
    types.zig              shared public structs: Usage, Completion, StructuredSchema
    options.zig            Options + schema profile defaults
    session.zig            Session arena owner + session() helper
    create.zig             createWithArena parse/retry loop
    util.zig               tiny comptime helpers

  providers/
    mod.zig                provider re-exports
    openai.zig             OpenAI-compatible provider adapter
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

Core does not:

- know provider request internals
- validate JSON Schema constraints
- own HTTP details
- store provider-specific data

### Session owns result lifetime

`Session` owns arena for returned values. `session.create(T, req, .{})` returns `T` directly. Returned values die at `session.deinit()` or `session.reset()`.

### Provider owns transport + retry mutation

Provider adapter implements:

```zig
completeStructured(...)
appendRetry(...)
```

Provider decides:

- HTTP endpoint
- auth headers
- OpenAI-compatible URL override
- request JSON shape
- output text extraction
- provider error diagnostics
- retry message append format

`appendRetry` receives borrowed slices. Provider adapters must copy retry data if they retain it after returning.

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
