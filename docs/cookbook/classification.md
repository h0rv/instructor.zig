# Classify a request

Classify a support message and extract the fields needed for that case. A refund needs an order ID, while a bug report needs reproduction details.

## Parse a tagged union

Pass the OpenRouter session from the [shared setup](../cookbook.md#shared-setup). This is structured extraction, not the Decisions API.

```zig
const std = @import("std");
const instructor = @import("instructor");

const Refund = struct {
    order_id: []const u8,
    reason: []const u8,
};
const BugReport = struct {
    component: []const u8,
    reproduction: []const u8,
};
const FeatureRequest = struct {
    feature: []const u8,
    user_value: []const u8,
};
const Classification = union(enum) {
    refund: Refund,
    bug_report: BugReport,
    feature_request: FeatureRequest,
};
const Decision = struct {
    classification: Classification,
    pub const jsonschema = .{
        .name = "Decision",
        .description = "Classify a message into exactly one typed case.",
    };
};

fn classify(session: *instructor.Session(instructor.OpenAI)) !void {
    const decision = try session.create(Decision, instructor.OpenAI.Request{
        .model = "anthropic/claude-haiku-5.5",
        .messages = &.{.{ .role = .user, .content = "Order A-991 arrived broken. Please refund it." }},
    }, .{});
    switch (decision.classification) {
        .refund => |r| std.debug.print("refund {s}: {s}\n", .{ r.order_id, r.reason }),
        .bug_report => |b| std.debug.print("bug {s}: {s}\n", .{ b.component, b.reproduction }),
        .feature_request => |f| std.debug.print("feature {s}: {s}\n", .{ f.feature, f.user_value }),
    }
}
```

## Handle each case

The outer `Decision` struct keeps the union inside an object field. Each union case has its own payload. An exhaustive `switch` gives you the correct fields for that case without optional fields for every possible outcome.

The type name `Decision` here does not imply probabilities. If you only need a team choice and urgency, use [ticket routing](ticket-routing.md) with the [Decisions API](../decisions.md).

All extracted strings belong to the session. Copy them before resetting or deinitializing it. A typed refund classification is not authorization to issue a refund.

[Full source](../../examples/classify_union.zig)
