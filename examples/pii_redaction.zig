const std = @import("std");
const instructor = @import("instructor");

const EntityKind = enum { email, phone, name, address, api_key, other };

const PiiEntity = struct {
    kind: EntityKind,
    text: []const u8,
    replacement: []const u8,
    reason: []const u8,

    pub const jsonschema = .{
        .name = "PiiEntity",
        .description = "One sensitive text span and its safe replacement.",
    };
};

const RedactionPlan = struct {
    redacted_text: []const u8,
    entities: []const PiiEntity,
    safe_to_log: bool,

    pub const jsonschema = .{
        .name = "RedactionPlan",
        .description = "Detect PII and produce safe redacted text.",
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

    const text = "Robby Hill, robby@example.com, called from +1-415-555-0134. Token sk-live-abc123 should not be logged.";

    const plan = session.create(RedactionPlan, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Redact PII and secrets from this log line:\n" ++ text }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("safe_to_log={}\n{s}\n", .{ plan.safe_to_log, plan.redacted_text });
    for (plan.entities) |entity| {
        std.debug.print("{s}: {s} -> {s}\n", .{ @tagName(entity.kind), entity.text, entity.replacement });
    }
}
