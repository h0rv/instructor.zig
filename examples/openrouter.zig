const std = @import("std");
const instructor = @import("instructor");

const Person = struct {
    name: []const u8,
    age: u8,

    pub const jsonschema = .{
        .name = "Person",
        .description = "Extract person details.",
        .fields = .{
            .name = .{ .minLength = 1 },
            .age = .{ .minimum = 0, .maximum = 130 },
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

    const person = session.create(Person, instructor.OpenAI.Request{
        // Replace with any OpenRouter free model slug when testing.
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Robby is 24. Return only the structured person." }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("{s}: {}\n", .{ person.name, person.age });
}
