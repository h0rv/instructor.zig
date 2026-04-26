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
        .fields = .{
            .rating = .{ .minimum = 1, .maximum = 5 },
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

    const reviews = [_][]const u8{
        "The Mini Router is tiny and fast. Setup took two minutes. 5/5.",
        "The keyboard feels solid, but Bluetooth drops every hour. 2 stars.",
        "Cable works as expected. Nothing exciting, no issues.",
    };

    for (reviews, 0..) |text, i| {
        const prompt = try std.fmt.allocPrint(gpa, "Extract a product review:\n{s}", .{text});
        defer gpa.free(prompt);

        const review = session.create(Review, instructor.OpenAI.Request{
            .model = "openai/gpt-oss-20b:free",
            .messages = &.{.{ .role = .user, .content = prompt }},
        }, .{}) catch |err| {
            instructor.printError(err, &client);
            return err;
        };

        std.debug.print("#{} {s}: {s} rating={}\n", .{ i + 1, review.product, @tagName(review.sentiment), review.rating });
        for (review.key_phrases) |phrase| std.debug.print("  - {s}\n", .{phrase});
        session.reset();
    }
}
