const std = @import("std");
const instructor = @import("instructor");

// Requires OPENAI_API_KEY and makes one live request.
pub fn main(init: std.process.Init) !void {
    var client = try instructor.Client.fromEnv(init, .{
        .provider = .openai,
        .model = "gpt-6-luna",
    });
    defer client.deinit();

    const input =
        \\Search query: How do I reset my password?
        \\Passage: Select 'Forgot password' to receive a reset link.
    ;

    if (try client.decisions.condition(.{
        .input = input,
        .instructions = "Does the passage answer the search query?",
        // Choose this threshold using labeled examples.
        .threshold = 0.8,
    })) {
        std.debug.print("Include the passage.\n", .{});
    } else {
        std.debug.print("Leave the passage out.\n", .{});
    }
}
