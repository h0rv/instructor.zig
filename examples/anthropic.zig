const std = @import("std");
const instructor = @import("instructor");

const Person = struct {
    name: []const u8,
    age: u8,

    pub const jsonschema = .{
        .name = "Person",
        .fields = .{ .age = .{ .minimum = 0, .maximum = 130 } },
    };
};

pub fn main(init: std.process.Init) !void {
    var client = instructor.Anthropic.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .api_key = init.environ_map.get("ANTHROPIC_API_KEY") orelse return error.MissingApiKey,
        .max_tokens = 1024,
    });
    defer client.deinit();
    var session = instructor.session(init.gpa, &client);
    defer session.deinit();
    const person = session.create(Person, instructor.Anthropic.Request{
        .model = instructor.Anthropic.default_model,
        .messages = &.{
            .{ .role = .system, .content = "Extract the person from the user's text." },
            .{ .role = .user, .content = "Robby is 24." },
        },
    }, .{ .schema_options = instructor.anthropic_schema_options }) catch |err| {
        instructor.printError(err, &client);
        return err;
    };
    std.debug.print("{s}: {}\n", .{ person.name, person.age });
}
