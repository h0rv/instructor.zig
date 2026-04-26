const std = @import("std");
const instructor = @import("instructor");

const Confidence = enum { low, medium, high };

const SceneInspection = struct {
    setting: []const u8,
    summary: []const u8,
    visible_objects: []const []const u8,
    dominant_colors: []const []const u8,
    text_present: bool,
    confidence: Confidence,

    pub const jsonschema = .{
        .name = "inspect_image",
        .description = "Inspect an image and return structured visual observations.",
        .fields = .{
            .setting = .{ .description = "Short setting label, such as forest boardwalk or city street." },
            .summary = .{ .description = "One sentence visual summary." },
            .visible_objects = .{ .description = "Concrete visible objects." },
            .dominant_colors = .{ .description = "Dominant image colors." },
            .text_present = .{ .description = "Whether readable text appears in the image." },
            .confidence = .{ .description = "Confidence in the observation." },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const api_key = init.environ_map.get("OPENAI_API_KEY") orelse return error.MissingApiKey;

    var client = instructor.OpenAI.init(.{
        .allocator = gpa,
        .io = init.io,
        .api_key = api_key,
        .endpoint = .responses,
    });
    defer client.deinit();

    var session = instructor.session(gpa, &client);
    defer session.deinit();

    const images = [_]instructor.OpenAI.Image{.{
        .url = "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/640px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg",
        .detail = "low",
    }};

    const inspection = session.create(SceneInspection, instructor.OpenAI.Request{
        .model = "gpt-5.4-nano",
        .messages = &.{.{
            .role = .user,
            .content = "Inspect this image. Return only structured observations.",
            .images = &images,
        }},
        .max_output_tokens = 512,
    }, .{}) catch |err| {
        instructor.printError(err, &client);
        return err;
    };

    std.debug.print("setting: {s}\n", .{inspection.setting});
    std.debug.print("summary: {s}\n", .{inspection.summary});
    std.debug.print("confidence: {s}\n", .{@tagName(inspection.confidence)});
    for (inspection.visible_objects) |object| std.debug.print("object: {s}\n", .{object});
}
