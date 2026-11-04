const std = @import("std");
const instructor = @import("instructor");

const Team = enum { billing, technical, other };
const TicketDecision = struct {
    team: Team,
    urgent: bool,
};

// Requires OPENAI_API_KEY and makes one live request.
pub fn main(init: std.process.Init) !void {
    var client = try instructor.Client.fromEnv(init, .{
        .provider = .openai,
        .model = "gpt-6-luna",
    });
    defer client.deinit();

    const questions = instructor.decisions.Questions(TicketDecision).init(&client, .{
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
