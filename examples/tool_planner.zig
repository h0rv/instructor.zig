const std = @import("std");
const instructor = @import("instructor");

const SearchType = enum { web, image, video };

const Search = struct {
    topic: []const u8,
    query: []const u8,
    type: SearchType,

    pub const jsonschema = .{
        .name = "Search",
        .description = "A search action to execute.",
        .fields = .{
            .topic = .{ .description = "Topic of the search." },
            .query = .{ .description = "Search query." },
            .type = .{ .description = "Type of search: web, image, or video." },
        },
    };
};

const SearchPlan = struct {
    searches: []const Search,

    pub const jsonschema = .{
        .name = "SearchPlan",
        .description = "A list of search actions to execute.",
        .fields = .{
            .searches = .{ .description = "Search actions." },
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

    const plan = session.create(SearchPlan, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{
            .role = .user,
            .content = "Create exactly four search actions: image search for a cat picture, video search for a dog video, web search for cat taxonomy, web search for dog taxonomy.",
        }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    for (plan.searches) |search| {
        std.debug.print("search {s}: {s}\n", .{ @tagName(search.type), search.query });
    }
}
