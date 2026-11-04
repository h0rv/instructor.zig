const std = @import("std");
const instructor = @import("instructor");

const Team = enum { billing, technical, other };
const TicketDecision = struct {
    team: Team,
    urgent: bool,
    blocked_probability: f64,
};

const questions: instructor.decisions.Questions(TicketDecision) = .{
    .team = .{
        .instructions = "Which team should review this support ticket?",
        .descriptions = &.{
            .{ .value = .billing, .description = "Charges, invoices, or refunds." },
            .{ .value = .technical, .description = "Problems using the product." },
            .{ .value = .other, .description = "Requests outside these categories." },
        },
    },
    .urgent = .{
        .instructions = "Does the ticket describe an issue that needs attention today?",
        // Illustrative only. Choose thresholds using labeled tickets.
        .threshold = 0.8,
    },
    .blocked_probability = .{ .predicate = .{
        .instructions = "Is the customer unable to continue their work?",
    } },
};

// This example makes one live request and requires OPENAI_API_KEY.
pub fn main(init: std.process.Init) !void {
    var client = try instructor.Client.fromEnv(init, .{
        .provider = .openai,
        .model = "gpt-6-luna",
    });
    defer client.deinit();

    const ticket = "I was charged twice. Please fix this today. I can still use the product.";
    var decision = try client.decisions.parse(TicketDecision, .{
        .input = ticket,
        .questions = questions,
    });
    defer decision.deinit();

    const queue = switch (decision.value.team) {
        .billing => "billing review",
        .technical => "technical review",
        .other => "general review",
    };
    std.debug.print("Queue: {s}; selected choice probability: {d:.2}\n", .{
        queue,
        decision.details.team.probabilities.get(decision.value.team),
    });
    if (decision.value.urgent) {
        std.debug.print("Flag for attention today.\n", .{});
    } else {
        std.debug.print("Keep the normal review priority.\n", .{});
    }
    std.debug.print("Urgency probability: {d:.2}; blocked probability: {d:.2}\n", .{
        decision.details.urgent.probability,
        decision.value.blocked_probability,
    });
}
