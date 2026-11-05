# Inspect an image

Extract a typed description of an image, including visible objects and whether it contains readable text. Use the lower-level provider because the common client's resources currently accept text only.

## Send an image with text

Pass a `Session(instructor.OpenAI)` created with an OpenAI provider using `.endpoint = .responses` and an OpenAI API key. Unlike the [shared OpenRouter setup](../cookbook.md#shared-setup), keep the default OpenAI base URL. The full source includes that configuration.

```zig
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
    };
};

fn inspectImage(session: *instructor.Session(instructor.OpenAI)) !void {
    const images = [_]instructor.OpenAI.Image{.{
        .url = "https://upload.wikimedia.org/wikipedia/commons/a/a9/Example.jpg",
        .detail = "low",
    }};
    const inspection = try session.create(SceneInspection, instructor.OpenAI.Request{
        .model = "gpt-6-luna",
        .messages = &.{.{
            .role = .user,
            .content = "Inspect this image. Return only structured observations.",
            .images = &images,
        }},
        .max_output_tokens = 512,
    }, .{});
    std.debug.print("{s}: {s}\n", .{ inspection.setting, inspection.summary });
    std.debug.print("text={}, confidence={s}\n", .{
        inspection.text_present, @tagName(inspection.confidence),
    });
    for (inspection.visible_objects) |object| {
        std.debug.print("object: {s}\n", .{object});
    }
}
```

## Interpret observations carefully

The image URL is input, not an expected result. Use a URL the provider can access and a model that supports image input. `detail = "low"` requests lower image detail.

`text_present` indicates readable text, but does not return a transcription. `confidence` is a model-generated enum label, not a measured probability or a Decisions score. Review observations before relying on them.

The returned strings and arrays belong to the session arena. Use or copy them before resetting or deinitializing the session. The [client guide](../client.md) describes the common API's text-only limits.

[Full source](../../examples/multimodal_inspection.zig)
