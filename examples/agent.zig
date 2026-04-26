const std = @import("std");
const instructor = @import("instructor");

const Search = struct {
    query: []const u8,

    pub const jsonschema = .{
        .description = "Search local documentation.",
        .fields = .{
            .query = .{ .description = "Search query." },
        },
    };
};

const Lookup = struct {
    id: []const u8,

    pub const jsonschema = .{
        .description = "Read one document by id.",
        .fields = .{
            .id = .{ .description = "Document id from search results." },
        },
    };
};

const Finish = struct {
    answer: []const u8,

    pub const jsonschema = .{
        .description = "Finish with final answer.",
        .fields = .{
            .answer = .{ .description = "Final answer grounded in tool results." },
        },
    };
};

const Action = union(enum) {
    search: Search,
    lookup: Lookup,
    finish: Finish,

    pub const jsonschema = .{
        .name = "AgentAction",
        .description = "Exactly one next agent action. Use native Zig tagged-union JSON: {\"search\":{...}}, {\"lookup\":{...}}, or {\"finish\":{...}}.",
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

    var messages: [16]instructor.OpenAI.Message = undefined;
    var message_count: usize = 0;
    messages[message_count] = .{
        .role = .system,
        .content = "You are a small research agent. Choose exactly one action per turn. Search first, lookup useful ids from search results, then finish. Use only tool results for the final answer.",
    };
    message_count += 1;
    messages[message_count] = .{
        .role = .user,
        .content = "Find what changed about Zig 0.16 std.Io and answer in one sentence.",
    };
    message_count += 1;

    var owned_messages: [8][]u8 = undefined;
    var owned_count: usize = 0;
    defer for (owned_messages[0..owned_count]) |message| gpa.free(message);

    for (0..5) |_| {
        const action = session.create(Action, instructor.OpenAI.Request{
            .model = "nvidia/nemotron-3-nano-30b-a3b:free",
            .messages = messages[0..message_count],
        }, .{}) catch |err| {
            instructor.printError(err, &client);
            return err;
        };

        switch (action) {
            .search => |search| {
                const result = runSearch(search.query);
                std.debug.print("search: {s}\n", .{search.query});
                try appendToolResult(gpa, &messages, &message_count, &owned_messages, &owned_count, "search", search.query, result);
            },
            .lookup => |lookup| {
                const result = runLookup(lookup.id);
                std.debug.print("lookup: {s}\n", .{lookup.id});
                try appendToolResult(gpa, &messages, &message_count, &owned_messages, &owned_count, "lookup", lookup.id, result);
            },
            .finish => |finish| {
                std.debug.print("answer: {s}\n", .{finish.answer});
                return;
            },
        }
    }

    return error.MaxAgentTurns;
}

fn appendToolResult(
    allocator: std.mem.Allocator,
    messages: *[16]instructor.OpenAI.Message,
    message_count: *usize,
    owned_messages: *[8][]u8,
    owned_count: *usize,
    tool: []const u8,
    input: []const u8,
    result: []const u8,
) !void {
    if (message_count.* >= messages.len) return error.TooManyMessages;
    if (owned_count.* >= owned_messages.len) return error.TooManyToolResults;

    const content = try std.fmt.allocPrint(
        allocator,
        "Tool result from {s}({s}):\n{s}\nChoose the next action.",
        .{ tool, input, result },
    );
    errdefer allocator.free(content);

    owned_messages[owned_count.*] = content;
    owned_count.* += 1;

    messages[message_count.*] = .{ .role = .user, .content = content };
    message_count.* += 1;
}

fn runSearch(query: []const u8) []const u8 {
    _ = query;
    return
    \\results:
    \\- zig-io: Zig 0.16 moved toward std.Io as the main I/O surface.
    \\- zig-process-init: Zig 0.16 main can accept std.process.Init for allocator, IO, and environment.
    ;
}

fn runLookup(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "zig-io")) {
        return "zig-io: Zig 0.16 uses std.Io.Writer and std.Io.Reader style APIs; examples can use std.debug.print for small debug output.";
    }
    if (std.mem.eql(u8, id, "zig-process-init")) {
        return "zig-process-init: pub fn main(init: std.process.Init) !void gives access to init.gpa, init.io, and init.environ_map.";
    }
    return "unknown document id";
}
