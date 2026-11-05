# Cookbook

Recipes for extracting typed data and making model decisions. The snippets omit process startup and credential loading.

## Text and structured output

Use these recipes to parse model output into Zig types. See the [client guide](client.md) for ordinary text generation without a schema.

- [Extract a product](cookbook/product.md). Start with the common `Client` and an owned result.
- [Extract an invoice](cookbook/invoice.md). Parse nested line items and integer money amounts.
- [Summarize meeting actions](cookbook/meeting-actions.md). Extract a summary and tasks with owners and due dates.
- [Classify a request](cookbook/classification.md). Switch on a tagged union with different fields for each case.
- [Process reviews](cookbook/reviews.md). Validate ratings and release session memory between requests.
- [Inspect an image](cookbook/image-inspection.md). Use the lower-level provider for typed visual observations.

## Decisions

Use these recipes for fixed questions with typed choices and probabilities, rather than extracting strings or nested objects. See the [Decisions guide](decisions.md) for provider configuration.

- [Branch on relevance](cookbook/boolean-branching.md). Compare a predicate probability with a threshold.
- [Route a ticket](cookbook/ticket-routing.md). Ask reusable team and urgency questions together.

## Shared setup

Product extraction and the Decisions recipes take a configured `*instructor.Client`. Configure it as described in the [client guide](client.md). Decisions requires OpenAI or a TypeSafe-compatible service.

The invoice, meeting, classification, and review functions take a `*instructor.Session(instructor.OpenAI)`. Create the lower-level provider and session once, with application values for `allocator`, `io`, and `api_key`:

```zig
const instructor = @import("instructor");

var provider = instructor.OpenAI.init(.{
    .allocator = allocator,
    .io = io,
    .api_key = api_key,
    .base_url = "https://openrouter.ai/api/v1",
    .endpoint = .chat_completions,
});
defer provider.deinit();
var session = instructor.session(allocator, &provider);
defer session.deinit();
```

Pass `&session` to those functions. Image inspection uses a separate OpenAI Responses provider, as noted in that recipe. Keep providers alive until their sessions are deinitialized. Session values remain valid until `session.reset()` or `session.deinit()`; they have no individual `deinit` method.
