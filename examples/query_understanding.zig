const std = @import("std");
const instructor = @import("instructor");

const Sort = enum { relevance, stars, recent, issues };

const SearchFilters = struct {
    language: ?[]const u8,
    min_stars: ?u32,
    topics: []const []const u8,
    sort: Sort,

    pub const jsonschema = .{
        .name = "SearchFilters",
        .description = "Structured filters for repository search.",
    };
};

const SearchQuery = struct {
    rewritten_query: []const u8,
    filters: SearchFilters,
    must_have_terms: []const []const u8,
    excluded_terms: []const []const u8,

    pub const jsonschema = .{
        .name = "SearchQuery",
        .description = "Turn a natural-language request into search filters.",
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

    const query = session.create(SearchQuery, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Find mature Zig JSON/schema libraries with more than 100 stars, not abandoned, sort by stars." }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("query: {s}\n", .{query.rewritten_query});
    std.debug.print("sort={s} min_stars={?}\n", .{ @tagName(query.filters.sort), query.filters.min_stars });
    if (query.filters.language) |language| std.debug.print("language: {s}\n", .{language});
    for (query.filters.topics) |topic| std.debug.print("topic: {s}\n", .{topic});
}
