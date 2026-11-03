const std = @import("std");
const instructor = @import("instructor");

const Person = struct {
    name: []const u8,
    age: u8,
};

// This demonstration performs no network I/O. A real adapter can use any client.
fn send(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, request: instructor.http.Request) !instructor.http.Response {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body.?, .{});
    defer parsed.deinit();

    const body = if (parsed.value.object.get("text") != null)
        \\{"output_text":"{\"name\":\"Robby\",\"age\":24}"}
    else
        \\{"output_text":"Hello"}
    ;
    return .{
        .allocator = allocator,
        .status = .ok,
        .body = try allocator.dupe(u8, body),
    };
}

pub fn main(init: std.process.Init) !void {
    var ai = try instructor.Client.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .provider = .{ .openai = .{ .api_key = "" } },
        .model = "example-model",
        .transport = .{ .send_fn = send },
    });
    defer ai.deinit();

    var greeting = try ai.text("Say hello.");
    defer greeting.deinit();

    var person = try ai.extract(Person, .{ .prompt = "Robby is 24." });
    defer person.deinit();

    std.debug.print("{s}\n{s}: {}\n", .{ greeting.text, person.value.name, person.value.age });
}
