const std = @import("std");
const instructor = @import("instructor");

// These thresholds are illustrative. Choose them using labeled passages.
const review_lower_bound = 0.2;
const relevance_threshold = 0.8;
const question = "Does the passage directly help answer the search query?";

// This example makes one live request and requires OPENAI_API_KEY.
pub fn main(init: std.process.Init) !void {
    var client = try instructor.Client.fromEnv(init, .{
        .provider = .openai,
        .model = "gpt-6-luna",
    });
    defer client.deinit();

    const input =
        \\Search query: How do I reset my password?
        \\Passage: Select 'Forgot password' on the sign-in page to receive a reset link.
    ;
    var decision = try client.decisions.parse(bool, .{
        .input = input,
        .questions = .{
            .instructions = question,
            .threshold = relevance_threshold,
        },
    });
    defer decision.deinit();

    const probability = decision.details.probability;
    std.debug.print("Relevance probability: {d:.2}\n", .{probability});
    if (probability > review_lower_bound and probability < relevance_threshold) {
        std.debug.print("Send the passage for manual review.\n", .{});
        return;
    }

    // The model estimates relevance. Ordinary Zig code controls the branch.
    if (decision.value) {
        std.debug.print("Include the passage in the search results.\n", .{});
    } else {
        std.debug.print("Leave the passage out of the search results.\n", .{});
    }
}
