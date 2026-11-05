# Branch on relevance

Decide whether a passage answers a search query, then use an ordinary Zig `if` to include or omit it. Use Decisions when you need a fixed boolean answer rather than extracted text.

## Apply a probability threshold

Pass a configured common `Client` for OpenAI with `gpt-6-luna`, or a TypeSafe-compatible service. See [Decisions provider configuration](../decisions.md#provider-configuration).

```zig
const std = @import("std");
const instructor = @import("instructor");

fn checkRelevance(client: *instructor.Client) !void {
    const input =
        \\Search query: How do I reset my password?
        \\Passage: Select 'Forgot password' to receive a reset link.
    ;
    const relevant = try client.decisions.condition(.{
        .input = input,
        .instructions = "Does the passage answer the search query?",
        .threshold = 0.8,
    });

    if (relevant) {
        std.debug.print("Include the passage.\n", .{});
    } else {
        std.debug.print("Leave the passage out.\n", .{});
    }
}
```

## Choose the threshold from examples

The result is true when the reported predicate probability is at least `0.8`. The probability is a model estimate, not a guarantee that the passage is relevant. Choose a threshold using labeled examples from your application. Without an explicit threshold, the default is `0.5`.

Keep both the query and passage in the input. Keep the fixed question in `instructions`, separate from the text being judged.

`condition` frees the response internally and returns a plain `bool`. There is no result to deinitialize. The caller owns the client. Errors propagate through `try`; a failed request is not silently treated as false.

[Full source](../../examples/smart_if.zig)
