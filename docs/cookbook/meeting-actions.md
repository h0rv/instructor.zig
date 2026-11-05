# Summarize meeting actions

Extract a short summary and concrete tasks from meeting notes. Keep the owner and due timeframe beside each task so you can review assignments without rereading the whole transcript.

## Extract tasks

Pass the OpenRouter session from the [shared setup](../cookbook.md#shared-setup).

```zig
const std = @import("std");
const instructor = @import("instructor");

const Priority = enum { low, medium, high };
const ActionItem = struct {
    owner: []const u8,
    task: []const u8,
    priority: Priority,
    due: []const u8,
};
const MeetingActions = struct {
    summary: []const u8,
    actions: []const ActionItem,
    pub const jsonschema = .{
        .name = "MeetingActions",
        .description = "Meeting summary and action items.",
        .fields = .{
            .summary = .{ .description = "One-sentence meeting summary." },
        },
    };
};

fn extractActions(session: *instructor.Session(instructor.OpenAI)) !void {
    const transcript =
        \\Maintainer: I will update the API docs by Friday. This is high priority.
        \\Reviewer: I will check schema compatibility tomorrow. Medium priority.
        \\Maintainer: Launch notes can wait until next week.
    ;
    const result = try session.create(MeetingActions, instructor.OpenAI.Request{
        .model = "anthropic/claude-haiku-5.5",
        .messages = &.{.{ .role = .user, .content = "Extract action items:\n" ++ transcript }},
    }, .{});
    std.debug.print("summary: {s}\n", .{result.summary});
    for (result.actions) |item| {
        std.debug.print("{s} [{s}] {s}, due {s}\n", .{
            item.owner, @tagName(item.priority), item.task, item.due,
        });
    }
}
```

## Review assignments

`priority` is an enum, but `due` is text. A phrase such as "tomorrow" is not a normalized calendar date. Review unclear owners or deadlines before creating tasks in another system. Schema validation does not prove that the model understood an assignment correctly.

The summary and action records use session memory. There is no per-result cleanup. Copy anything you need to retain before `session.reset()` or `session.deinit()`.

[Full source](../../examples/action_items.zig)
