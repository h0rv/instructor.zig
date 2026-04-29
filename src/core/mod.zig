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
pub const HookEvent = types.HookEvent;
pub const HookInfo = types.HookInfo;
pub const Hooks = types.Hooks;
pub const CreateResult = types.CreateResult;

pub const Options = options.Options;
pub const FieldNaming = options.FieldNaming;
pub const RootWrapper = options.RootWrapper;
pub const ObjectRootWrapper = options.ObjectRootWrapper;
pub const openai_schema_options = options.openai_schema_options;

pub const Error = create.Error;
pub const createWithArena = create.createWithArena;
pub const createDetailedWithArena = create.createDetailedWithArena;
pub const schemaAlloc = create.schemaAlloc;
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

const TestPerson = struct {
    name: []const u8,
    age: u8,

    pub const jsonschema = .{ .name = "Person" };
};

test "session create returns parsed value" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    var provider: testing.Provider = .{
        .responses = &.{"{\"name\":\"Ada\",\"age\":42}"},
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const person = try s.create(TestPerson, testing.Request{}, .{});

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqualStrings("Ada", person.name);
    try std.testing.expectEqual(@as(u8, 42), person.age);
    try std.testing.expectEqual(@as(u64, 3), s.usage.total_tokens);
}

test "session create retries parse errors" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    var provider: testing.Provider = .{
        .responses = &.{ "not json", "{\"name\":\"Grace\",\"age\":37}" },
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const person = try s.create(TestPerson, testing.Request{}, .{});

    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), provider.retry_count);
    try std.testing.expect(provider.saw_parse_retry);
    try std.testing.expectEqualStrings("Grace", person.name);
    try std.testing.expectEqual(@as(u64, 6), s.usage.total_tokens);
}

test "session create retries validation errors by default" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const User = struct {
        name: []const u8,

        pub const jsonschema = .{
            .name = "User",
            .fields = .{
                .name = .{ .minLength = 1 },
            },
        };
    };

    var provider: testing.Provider = .{
        .responses = &.{ "{\"name\":\"\"}", "{\"name\":\"Ada\"}" },
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const user = try s.create(User, testing.Request{}, .{});

    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), provider.retry_count);
    try std.testing.expect(provider.saw_validation_retry);
    try std.testing.expectEqualStrings("Ada", user.name);
}

test "validation can be disabled" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const User = struct {
        name: []const u8,

        pub const jsonschema = .{
            .name = "User",
            .fields = .{
                .name = .{ .minLength = 1 },
            },
        };
    };

    var provider: testing.Provider = .{
        .responses = &.{"{\"name\":\"\"}"},
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const user = try s.create(User, testing.Request{}, .{ .validate = false });

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), provider.retry_count);
    try std.testing.expectEqualStrings("", user.name);
}

test "session createDetailed exposes raw response and per-call usage" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    var provider: testing.Provider = .{
        .responses = &.{"{\"name\":\"Ada\",\"age\":42}"},
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const result = try s.createDetailed(TestPerson, testing.Request{}, .{});

    try std.testing.expectEqualStrings("Ada", result.value.name);
    try std.testing.expectEqual(@as(u64, 3), result.usage.total_tokens);
    try std.testing.expectEqual(@as(u64, 3), s.last_usage.total_tokens);
    try std.testing.expectEqualStrings(result.text, s.last_text.?);
    try std.testing.expectEqualStrings(result.raw_response, s.last_raw_response.?);
    try std.testing.expect(std.mem.indexOf(u8, result.raw_response, "mock response 0") != null);
}

test "schemaAlloc uses jsonschema tool descriptor" {
    const std = @import("std");

    const Person = struct {
        name: []const u8,

        pub const jsonschema = .{
            .name = "Person",
            .description = "Extract person.",
        };
    };

    var schema = try schemaAlloc(Person, std.testing.allocator, openai_schema_options);
    defer schema.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Person", schema.name);
    try std.testing.expectEqualStrings("Extract person.", schema.description.?);
    try std.testing.expect(std.mem.indexOf(u8, schema.schema_json, "\"type\":\"object\"") != null);
}

test "schema options expose field naming" {
    const std = @import("std");

    const User = struct {
        first_name: []const u8,
    };

    var schema = try schemaAlloc(User, std.testing.allocator, comptime blk: {
        var opts = openai_schema_options;
        opts.field_naming = .camelCase;
        break :blk opts;
    });
    defer schema.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, schema.schema_json, "firstName") != null);
}

test "explicit object wrapper supports root arrays" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const Item = struct {
        task: []const u8,
    };

    const Items = struct {
        items: []const Item,

        pub const jsonschema = .{
            .name = "Items",
            .description = "Object root wrapper for extracted items.",
            .fields = .{
                .items = .{ .description = "Extracted items." },
            },
        };
    };

    var provider: testing.Provider = .{
        .responses = &.{"{\"items\":[{\"task\":\"ship docs\"},{\"task\":\"write tests\"}]}"},
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();

    const result = try s.create(Items, testing.Request{}, .{});

    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("ship docs", result.items[0].task);
    try std.testing.expectEqualStrings("write tests", result.items[1].task);
}

test "session hooks report validation retry flow" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const User = struct {
        name: []const u8,

        pub const jsonschema = .{
            .name = "User",
            .fields = .{
                .name = .{ .minLength = 1 },
            },
        };
    };

    const HookState = struct {
        events: [8]HookEvent = undefined,
        len: usize = 0,
        validation_error_name: ?[]const u8 = null,
        saw_validation_errors: bool = false,

        fn onEvent(ctx: ?*anyopaque, event: HookEvent, info: HookInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events[self.len] = event;
            self.len += 1;
            if (event == .validation_error) {
                self.validation_error_name = info.error_name;
                self.saw_validation_errors = info.validation_errors != null;
            }
        }
    };

    var state: HookState = .{};
    var provider: testing.Provider = .{
        .responses = &.{ "{\"name\":\"\"}", "{\"name\":\"Grace\"}" },
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();
    s.setHooks(.{ .ctx = &state, .on_event = HookState.onEvent });

    const user = try s.create(User, testing.Request{}, .{});

    try std.testing.expectEqualStrings("Grace", user.name);
    try std.testing.expectEqual(@as(usize, 6), state.len);
    try std.testing.expectEqual(HookEvent.request_start, state.events[0]);
    try std.testing.expectEqual(HookEvent.response_received, state.events[1]);
    try std.testing.expectEqual(HookEvent.validation_error, state.events[2]);
    try std.testing.expectEqual(HookEvent.retry, state.events[3]);
    try std.testing.expectEqual(HookEvent.response_received, state.events[4]);
    try std.testing.expectEqual(HookEvent.completion_done, state.events[5]);
    try std.testing.expectEqualStrings("ValidationError", state.validation_error_name.?);
    try std.testing.expect(state.saw_validation_errors);
}

test "session hooks report retry flow" {
    const std = @import("std");
    const testing = @import("../providers/testing.zig");

    const HookState = struct {
        events: [8]HookEvent = undefined,
        len: usize = 0,
        parse_error_name: ?[]const u8 = null,

        fn onEvent(ctx: ?*anyopaque, event: HookEvent, info: HookInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events[self.len] = event;
            self.len += 1;
            if (event == .parse_error) self.parse_error_name = info.error_name;
        }
    };

    var state: HookState = .{};
    var provider: testing.Provider = .{
        .responses = &.{ "not json", "{\"name\":\"Grace\",\"age\":37}" },
    };

    var s = session(std.testing.allocator, &provider);
    defer s.deinit();
    s.setHooks(.{ .ctx = &state, .on_event = HookState.onEvent });

    const person = try s.create(TestPerson, testing.Request{}, .{});

    try std.testing.expectEqualStrings("Grace", person.name);
    try std.testing.expectEqual(@as(usize, 6), state.len);
    try std.testing.expectEqual(HookEvent.request_start, state.events[0]);
    try std.testing.expectEqual(HookEvent.response_received, state.events[1]);
    try std.testing.expectEqual(HookEvent.parse_error, state.events[2]);
    try std.testing.expectEqual(HookEvent.retry, state.events[3]);
    try std.testing.expectEqual(HookEvent.response_received, state.events[4]);
    try std.testing.expectEqual(HookEvent.completion_done, state.events[5]);
    try std.testing.expect(state.parse_error_name != null);
}
