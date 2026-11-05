const std = @import("std");
const instructor = @import("instructor");

const Confidence = enum { low, medium, high };

const Citation = struct {
    quote: []const u8,
    explanation: []const u8,

    pub const jsonschema = .{
        .name = "Citation",
        .description = "Exact source quote supporting the answer.",
        .fields = .{
            .quote = .{ .description = "Exact copied quote from the source text." },
            .explanation = .{ .description = "Why this quote supports the answer." },
        },
    };
};

const GroundedAnswer = struct {
    answer: []const u8,
    confidence: Confidence,
    citations: []const Citation,

    pub const jsonschema = .{
        .name = "GroundedAnswer",
        .description = "Answer grounded in exact citations.",
        .fields = .{
            .answer = .{ .description = "Concise answer using only source facts." },
            .confidence = .{ .description = "Confidence based on source support." },
            .citations = .{ .description = "Exact quotes supporting the answer." },
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

    const source =
        \\Alex is 24 and works at a bookshop.
        \\They manage online orders and help customers find books.
        \\In April 2026, their priority is updating the stock list before the spring sale.
    ;

    const result = session.create(GroundedAnswer, instructor.OpenAI.Request{
        .model = "anthropic/claude-haiku-5.5",
        .messages = &.{.{
            .role = .user,
            .content = "Using only this source, answer: what is Alex's April 2026 priority? Include exact supporting quotes.\n\n" ++ source,
        }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("answer: {s}\nconfidence: {s}\n", .{ result.answer, @tagName(result.confidence) });
    for (result.citations) |citation| std.debug.print("quote: {s}\n", .{citation.quote});
}
