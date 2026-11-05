# Process reviews

Normalize several product reviews without retaining every response in memory. Parse one review at a time, use it, and reset the session before the next request.

## Validate each review

Pass the OpenRouter session from the [shared setup](../cookbook.md#shared-setup). Use a dedicated session because this function resets it after each successful extraction.

```zig
const std = @import("std");
const instructor = @import("instructor");

const Sentiment = enum { negative, neutral, positive };
const Review = struct {
    product: []const u8,
    sentiment: Sentiment,
    rating: u8,
    key_phrases: []const []const u8,
    pub const jsonschema = .{
        .name = "Review",
        .description = "Extract normalized product review fields.",
        .fields = .{ .rating = .{ .minimum = 1, .maximum = 5 } },
    };
};

fn processReviews(session: *instructor.Session(instructor.OpenAI)) !void {
    const reviews = [_][]const u8{
        "The Mini Router is tiny and fast. Setup took two minutes. 5/5.",
        "The keyboard feels solid, but Bluetooth drops every hour. 2 stars.",
    };
    for (reviews) |text| {
        const review = try session.create(Review, instructor.OpenAI.Request{
            .model = "anthropic/claude-haiku-5.5",
            .messages = &.{
                .{ .role = .system, .content = "Extract a product review." },
                .{ .role = .user, .content = text },
            },
        }, .{});
        std.debug.print("{s}: {s} rating={}\n", .{
            review.product, @tagName(review.sentiment), review.rating,
        });
        for (review.key_phrases) |phrase| {
            std.debug.print("phrase: {s}\n", .{phrase});
        }
        session.reset();
    }
}
```

## Release memory between requests

The `u8` field alone permits values outside the review scale. The schema's minimum and maximum constrain ratings to 1 through 5. Parsing or validation failures may cause retries.

`session.reset()` frees the arena, including strings and nested `key_phrases`. It also clears usage counters and last-response data. Print, store, or copy results before resetting. The caller still needs `session.deinit()`, including if extraction returns an error.

This is a sequential local loop, not a provider Batch API. Each extraction makes a separate request and may retry. Do not run concurrent calls on the same provider.

[Full source](../../examples/batch_extract.zig)
