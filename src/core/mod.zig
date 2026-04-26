const types = @import("types.zig");
const options = @import("options.zig");
const create = @import("create.zig");
const diagnostics = @import("diagnostics.zig");
const session_mod = @import("session.zig");

pub const Mode = types.Mode;
pub const Usage = types.Usage;
pub const StructuredSchema = types.StructuredSchema;
pub const RetryMessage = types.RetryMessage;
pub const Completion = types.Completion;
pub const Diagnostic = types.Diagnostic;

pub const Options = options.Options;
pub const openai_schema_options = options.openai_schema_options;

pub const Error = create.Error;
pub const createWithArena = create.createWithArena;
pub const diagnostic = diagnostics.diagnostic;
pub const printError = diagnostics.printError;
pub const writeError = diagnostics.writeError;

pub const Session = session_mod.Session;
pub const session = session_mod.session;

test {
    _ = types;
    _ = options;
    _ = create;
    _ = diagnostics;
    _ = session_mod;
}

test "session create returns parsed value" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const Person = struct {
        name: []const u8,
        age: u8,

        pub const jsonschema = .{ .name = "Person" };
    };

    var provider: testing.Provider = .{
        .responses = &.{"{\"name\":\"Ada\",\"age\":42}"},
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const person = try s.create(Person, testing.Request{}, .{});

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqualStrings("Ada", person.name);
    try std.testing.expectEqual(@as(u8, 42), person.age);
    try std.testing.expectEqual(@as(u64, 3), s.usage.total_tokens);
}

test "session create retries parse errors" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const Person = struct {
        name: []const u8,
        age: u8,

        pub const jsonschema = .{ .name = "Person" };
    };

    var provider: testing.Provider = .{
        .responses = &.{ "not json", "{\"name\":\"Grace\",\"age\":37}" },
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const person = try s.create(Person, testing.Request{}, .{});

    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), provider.retry_count);
    try std.testing.expectEqualStrings("Grace", person.name);
    try std.testing.expectEqual(@as(u64, 6), s.usage.total_tokens);
}
