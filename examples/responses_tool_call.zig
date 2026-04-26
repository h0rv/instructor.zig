const std = @import("std");
const instructor = @import("instructor");

const Severity = enum { low, medium, high };

const Incident = struct {
    title: []const u8,
    severity: Severity,
    impacted_services: []const []const u8,
    immediate_actions: []const []const u8,

    pub const jsonschema = .{
        .name = "record_incident",
        .description = "Record a typed incident summary from an incident update.",
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const api_key = init.environ_map.get("OPENAI_API_KEY") orelse return error.MissingApiKey;

    var client = instructor.OpenAI.init(.{
        .allocator = gpa,
        .io = init.io,
        .api_key = api_key,
        .endpoint = .responses,
    });
    defer client.deinit();

    var session = instructor.session(gpa, &client);
    defer session.deinit();

    const update =
        \\Checkout latency is above 3 seconds in us-east.
        \\Payments still succeed, but users see spinners.
        \\On-call is rolling back the cache change and watching error rates.
    ;

    const incident = session.create(Incident, instructor.OpenAI.Request{
        .model = "gpt-5.4-nano",
        .messages = &.{.{ .role = .user, .content = "Use the record_incident tool for this update:\n\n" ++ update }},
        .max_output_tokens = 512,
    }, .{ .mode = .responses_tool_call_required }) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("{s} [{s}]\n", .{ incident.title, @tagName(incident.severity) });
    for (incident.impacted_services) |service| std.debug.print("service: {s}\n", .{service});
    for (incident.immediate_actions) |action| std.debug.print("action: {s}\n", .{action});
}
