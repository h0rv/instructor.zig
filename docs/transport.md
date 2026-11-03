# HTTP transport

The common client accepts a transport independently of the model provider. The interface does not require `std.http.Client` or any other HTTP implementation.

```zig
pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send_fn: *const fn (
        ?*anyopaque,
        std.Io,
        std.mem.Allocator,
        Request,
    ) anyerror!Response,
};
```

`Request` contains `method`, `url`, `headers`, and an optional `body`. It also contains `max_response_bytes`. These values are borrowed only during `send_fn`. Copy anything your implementation needs to retain.

Instructor merges request extras before calling the transport. The URL includes encoded query parameters. The headers include request overrides without case-insensitive duplicates. The body includes merged JSON fields. Custom transports should send those values without rebuilding the body from a fixed list of known fields. See [request extras](client.md#request-extras) for the merge and validation rules.

`Response` contains an allocator, an HTTP status, and an owned `body`. Allocate the body with the allocator supplied to `send_fn`. Instructor releases that body with `Response.deinit`. Do not return borrowed buffers or static strings as the owned body.

## Ownership

Instructor borrows `ctx`. It never invokes a context destructor. Keep your transport alive until all client calls finish, then clean it up yourself.

The supplied `std.Io` belongs to the application. A transport backed by an existing HTTP client may use that client's own I/O implementation. The standard-library adapter always uses the I/O selected when its HTTP client was initialized.

The default `StdHttp` owns a standard-library client in stable heap storage. Its borrowed interface stays valid when the owner is moved. Do not copy an active owner. Do not use the interface after the owner is deinitialized.

## Adapter example

This callback is only a demonstration. It returns a synthetic OpenAI response without making a request:

```zig
fn send(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    request: instructor.http.Request,
) !instructor.http.Response {
    _ = request;

    return .{
        .allocator = allocator,
        .status = .ok,
        .body = try allocator.dupe(u8,
            \\{"output_text":"Hello"}
        ),
    };
}
```

Pass it in client configuration:

```zig
.transport = .{
    .ctx = null,
    .send_fn = send,
},
```

A real adapter replaces the synthetic response with a call to its HTTP implementation. See [`examples/custom_transport.zig`](../examples/custom_transport.zig) for a complete runnable example.

## Limits and credentials

Custom transports must honor `max_response_bytes` while reading the decompressed body. Bound error bodies too. The wrapper checks the returned length as a final guard, but it cannot prevent allocations made inside a custom implementation.

Do not follow redirects automatically. Requests may contain credentials. Do not log authorization headers or API keys.

The default transport keeps TLS verification enabled, disables redirects, and bounds decompressed response reads. A response exceeding the limit returns `error.ResponseTooLarge`. Transport failures are not treated as schema-validation failures and are not retried by the extraction loop.

This interface currently represents buffered HTTP exchanges. It does not claim streaming or WebSocket support. A future streaming interface must define chunk lifetimes and cancellation separately.
