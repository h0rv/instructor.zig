const std = @import("std");
const instructor = @import("instructor");

const Person = struct {
    name: []const u8,
    age: u8,
};

pub fn main(init: std.process.Init) !void {
    var ai = try instructor.Client.fromEnv(init, .{
        .provider = .anthropic,
        .model = "claude-haiku-4-5",
    });
    defer ai.deinit();

    var greeting = try ai.text("Say hello.");
    defer greeting.deinit();

    var person = try ai.extract(Person, .{ .prompt = "Robby is 24." });
    defer person.deinit();

    std.debug.print("{s}\n", .{greeting.text});
    std.debug.print("{s}: {}\n", .{ person.value.name, person.value.age });
}
