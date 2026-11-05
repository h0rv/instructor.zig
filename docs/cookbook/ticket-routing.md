# Route a ticket

Ask which team should review a ticket and whether it needs attention today. Define the questions once, then reuse them for incoming ticket text.

## Ask typed questions together

Pass a configured common `Client` for OpenAI with `gpt-6-luna`, or a TypeSafe-compatible service. See [Decisions provider configuration](../decisions.md#provider-configuration). These questions do not use structured text extraction.

```zig
const std = @import("std");
const instructor = @import("instructor");

const Team = enum { billing, technical, other };
const TicketDecision = struct {
    team: Team,
    urgent: bool,
};

fn routeTicket(client: *instructor.Client) !void {
    const questions = instructor.decisions.Questions(TicketDecision).init(client, .{
        .team = .{ .instructions = "Which team should review this support ticket?" },
        .urgent = .{
            .instructions = "Does the ticket need attention today?",
            .threshold = 0.8,
        },
    });
    const ticket = "I was charged twice. Please fix this today.";
    const decision = try questions.parse(.{ .input = ticket });

    const queue = switch (decision.team) {
        .billing => "billing",
        .technical => "technical",
        .other => "general",
    };
    std.debug.print("Queue: {s}\n", .{queue});
    if (decision.urgent) {
        std.debug.print("Review today.\n", .{});
    } else {
        std.debug.print("Use normal priority.\n", .{});
    }
}
```

## Reuse questions and inspect uncertainty

Initialization makes no request and allocates no memory. The question set borrows the client and instruction strings. Keep them alive while reusing it. Each `parse` call sends all questions in one request and returns a plain `TicketDecision`. It frees the response internally, so there is no per-result cleanup.

The enum selects a queue. The urgency boolean uses a probability threshold of `0.8`; choose that threshold from labeled tickets. This code prints a routing choice but does not enqueue or modify a ticket.

If you need to handle uncertain answers separately, use `questions.parseDetailed` and deinitialize its owned result. See [keeping probabilities](../decisions.md#keep-probabilities-when-needed). To extract case-specific strings instead, see [request classification](classification.md).

[Full source](../../examples/decisions.zig)
