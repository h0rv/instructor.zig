const std = @import("std");
const instructor = @import("instructor");

const Grade = enum { fail, pass, excellent };

const Judgment = struct {
    grade: Grade,
    score: u8,
    passed: bool,
    reasons: []const []const u8,
    suggested_fix: ?[]const u8,

    pub const jsonschema = .{
        .name = "Judgment",
        .description = "Evaluate an answer against a rubric.",
        .fields = .{
            .score = .{ .minimum = 0, .maximum = 10 },
            .reasons = .{ .description = "Concrete rubric-based reasons." },
            .suggested_fix = .{ .description = "Null if no fix is needed." },
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

    const prompt =
        \\Rubric: answer must mention explicit allocators, session-owned lifetime,
        \\and that returned strings are invalid after session.reset().
        \\
        \\Answer: instructor.zig returns typed structs from JSON. It uses an arena
        \\inside a session so callers should keep the session alive while reading data.
    ;

    const judgment = session.create(Judgment, instructor.OpenAI.Request{
        .model = "openai/gpt-oss-20b:free",
        .messages = &.{.{ .role = .user, .content = "Judge this answer. Be strict.\n\n" ++ prompt }},
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("grade={s} score={} passed={}\n", .{ @tagName(judgment.grade), judgment.score, judgment.passed });
    for (judgment.reasons) |reason| std.debug.print("- {s}\n", .{reason});
    if (judgment.suggested_fix) |fix| std.debug.print("fix: {s}\n", .{fix});
}
