const std = @import("std");
const instructor = @import("instructor");

const Priority = enum { low, medium, high };

const ActionItem = struct {
    owner: []const u8,
    task: []const u8,
    priority: Priority,
    due: []const u8,

    pub const jsonschema = .{
        .name = "ActionItem",
        .description = "A concrete task from a meeting transcript.",
        .fields = .{
            .owner = .{ .description = "Person responsible." },
            .task = .{ .description = "Specific task to complete." },
            .priority = .{ .description = "Task priority." },
            .due = .{ .description = "Due date or timeframe." },
        },
    };
};

const MeetingActions = struct {
    summary: []const u8,
    actions: []const ActionItem,

    pub const jsonschema = .{
        .name = "MeetingActions",
        .description = "Meeting summary and action items.",
        .fields = .{
            .summary = .{ .description = "One-sentence meeting summary." },
            .actions = .{ .description = "Action items extracted from transcript." },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const api_key = init.environ_map.get("OPENROUTER_API_KEY") orelse return error.MissingApiKey;

    var client = instructor.OpenAI.init(.{
        .allocator = gpa,
        .io = init.io,
        .api_key = api_key,
        .base_url = "https://openrouter.ai/api/v1",
        .endpoint = .chat_completions,
        .http_referer = "https://github.com/h0rv/instructor.zig",
        .app_name = "instructor.zig",
    });
    defer client.deinit();

    var session = instructor.session(gpa, &client);
    defer session.deinit();

    const transcript =
        \\Maya: Robby, can you finish the OpenRouter example today?
        \\Robby: Yes, I will clean up the API docs and add a function-calling style demo by Friday.
        \\Maya: Great. I'll review jsonschema compatibility tomorrow. The launch notes can wait until next week.
    ;

    const result = session.create(MeetingActions, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Extract action items from this transcript:\n\n" ++ transcript }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("summary: {s}\n", .{result.summary});
    for (result.actions) |item| std.debug.print("{s} [{s}] {s} — {s}\n", .{ item.owner, @tagName(item.priority), item.task, item.due });
}
