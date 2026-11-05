# Extract a product

Turn a short product description into fields that your application can use directly. Define the expected shape as a Zig struct instead of parsing a text answer yourself.

## Extract and read the result

Pass a configured common `Client`, for example Anthropic with `claude-haiku-5-5`. See [client configuration](../client.md). The function does not own the client.

```zig
const std = @import("std");
const instructor = @import("instructor");

const Product = struct {
    name: []const u8,
    price: f64,
    in_stock: bool,
};

fn extractProduct(client: *instructor.Client) !void {
    var product = try client.responses.parse(Product, .{
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

## Result lifetime

`parse` generates a schema from `Product` and validates the response. Parsing or validation failures can trigger retries. Read the typed fields through `product.value`.

The returned owner contains the strings and response data. Deinitialize it once, and do not copy an active owner. Its data can outlive the client if the backing allocator stays alive. Copy any fields you need after `product.deinit()` into application-owned memory.

Here `price` is a floating-point value for a simple product description. For money stored as integer cents, see [invoice extraction](invoice.md).

[Full source](../../examples/client.zig)
