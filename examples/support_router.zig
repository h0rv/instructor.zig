const std = @import("std");
const instructor = @import("instructor");

const Route = enum { billing, bug, feature, account, other };
const Priority = enum { low, medium, high, urgent };
const Confidence = enum { low, medium, high };

const TicketRoute = struct {
    route: Route,
    priority: Priority,
    confidence: Confidence,
    summary: []const u8,
    next_team: []const u8,

    pub const jsonschema = .{
        .name = "TicketRoute",
        .description = "Classify a support ticket for routing.",
        .fields = .{
            .route = .{ .description = "Best support queue." },
            .priority = .{ .description = "Urgency based on impact." },
            .confidence = .{ .description = "How certain the route is." },
            .summary = .{ .description = "One-sentence issue summary." },
            .next_team = .{ .description = "Team that should handle the ticket." },
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

    const ticket =
        \\Subject: Card charged twice
        \\I upgraded to Pro, got an error, retried, and now see two $29 charges.
        \\Please fix this quickly because our finance report closes today.
    ;

    const route = session.create(TicketRoute, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Route this support ticket:\n\n" ++ ticket }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("route: {s} priority={s} confidence={s}\n", .{ @tagName(route.route), @tagName(route.priority), @tagName(route.confidence) });
    std.debug.print("team: {s}\nsummary: {s}\n", .{ route.next_team, route.summary });
}
