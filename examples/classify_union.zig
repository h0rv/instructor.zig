const std = @import("std");
const instructor = @import("instructor");

const Refund = struct {
    order_id: []const u8,
    reason: []const u8,
};

const BugReport = struct {
    component: []const u8,
    reproduction: []const u8,
};

const FeatureRequest = struct {
    feature: []const u8,
    user_value: []const u8,
};

const Classification = union(enum) {
    refund: Refund,
    bug_report: BugReport,
    feature_request: FeatureRequest,
};

const Decision = struct {
    classification: Classification,

    pub const jsonschema = .{
        .name = "Decision",
        .description = "Classify a message into exactly one typed case.",
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

    const decision = session.create(Decision, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Order A-991 arrived broken. Please refund it." }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    switch (decision.classification) {
        .refund => |refund| std.debug.print("refund {s}: {s}\n", .{ refund.order_id, refund.reason }),
        .bug_report => |bug| std.debug.print("bug {s}: {s}\n", .{ bug.component, bug.reproduction }),
        .feature_request => |feature| std.debug.print("feature {s}: {s}\n", .{ feature.feature, feature.user_value }),
    }
}
