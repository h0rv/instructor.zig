const std = @import("std");
const instructor = @import("instructor");

const Team = enum { billing, technical, other };
const TicketDecision = struct { team: Team, urgent: bool };

const Fixture = struct {
    requests: usize = 0,

    // Return a fixed SDK response without opening a network connection.
    fn send(ctx: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: instructor.http.Request) !instructor.http.Response {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        if (request.method != .POST or !std.mem.endsWith(u8, request.url, "/decisions"))
            return error.UnexpectedRequest;
        self.requests += 1;
        const body =
            \\{"model":"gpt-6-luna","answers":[{"type":"choice","name":"team","choice":"billing","probabilities":[{"value":"billing","probability":0.95},{"value":"technical","probability":0.03},{"value":"other","probability":0.02}],"confidence":0.925},{"type":"predicate","name":"urgent","probability":0.9}],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":100}}
        ;
        return .{
            .allocator = allocator,
            .status = .ok,
            .body = try allocator.dupe(u8, body),
        };
    }
};

// No API keys or network access are needed.
pub fn main(init: std.process.Init) !void {
    var fixture: Fixture = .{};
    var client = try instructor.Client.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .provider = .{ .openai = .{ .api_key = "" } },
        .model = "gpt-6-luna",
        .transport = .{ .ctx = &fixture, .send_fn = Fixture.send },
    });
    defer client.deinit();

    const questions: instructor.decisions.Questions(TicketDecision) = .{
        .team = .{ .instructions = "Which team should review this support ticket?" },
        .urgent = .{
            .instructions = "Does the ticket need attention today?",
            .threshold = 0.8,
        },
    };
    const ticket = "I was charged twice. Please fix this today.";
    var decision = try client.decisions.parse(TicketDecision, .{
        .input = ticket,
        .questions = questions,
    });
    defer decision.deinit();
    if (fixture.requests != 1) return error.UnexpectedRequestCount;

    const queue = switch (decision.value.team) {
        .billing => "billing review",
        .technical => "technical review",
        .other => "general review",
    };
    std.debug.print("Queue: {s}; billing probability: {d:.2}\n", .{
        queue,
        decision.details.team.probabilities.get(.billing),
    });
    if (decision.value.urgent) {
        std.debug.print("Flag for attention today.\n", .{});
    } else {
        std.debug.print("Keep the normal review priority.\n", .{});
    }
    std.debug.print("Urgency probability: {d:.2}; requests: {d}; input tokens: {d}\n", .{
        decision.details.urgent.probability,
        fixture.requests,
        decision.usage.input_tokens,
    });
}
