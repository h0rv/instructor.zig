# Cookbook

## Text and structured output

These examples generate text or parse model output into Zig types.

### Extract a product

Convert a product description into a `Product` with a name, price, and stock status. The common client generates the schema and returns an owned result.

```zig
const Product = struct {
    name: []const u8,
    price: f64,
    in_stock: bool,
};

var product = try client.responses.parse(Product, .{
    .input = "A coffee mug costs $12.50 and is in stock.",
});
defer product.deinit();
```

[Full example](../examples/client.zig)

### Extract an invoice

Parse invoice text into an invoice with nested line items. Amounts use integer cents rather than floating-point money values.

[Full example](../examples/invoice_extraction.zig)

### Summarize meeting actions

Extract a summary and action records with an owner, task, priority, and due date.

[Full example](../examples/action_items.zig)

### Classify a request

Parse a refund request, bug report, or feature request into a wrapped tagged union. This uses structured output, not the Decisions API.

[Full example](../examples/classify_union.zig)

### Process reviews

Parse reviews one at a time and reset the session memory after each result. This is a local loop, not a provider Batch API.

[Full example](../examples/batch_extract.zig)

### Inspect an image

Send an image through the lower-level OpenAI provider and return typed scene observations.

[Full example](../examples/multimodal_inspection.zig)

## Decisions

These examples ask fixed questions and return typed choices with probabilities.

### Branch on relevance

Ask whether a passage answers a query. The helper compares its probability with a threshold and frees the response.

```zig
if (try client.decisions.condition(.{
    .input = passage,
    .instructions = "Does this passage answer the search query?",
    .threshold = 0.8,
})) {
    includePassage();
}
```

[Full example](../examples/smart_if.zig)

### Route a ticket

Define reusable questions that return a team enum and an urgency boolean. The same questions work with the configured OpenAI or TypeSafe-compatible provider.

[Full example](../examples/decisions.zig)
