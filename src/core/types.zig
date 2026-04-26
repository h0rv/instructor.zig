const std = @import("std");

pub const Mode = enum {
    json_schema,
    json_object,
    tool_call,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.total_tokens += other.total_tokens;
    }
};

pub const StructuredSchema = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    schema_json: []const u8,
    strict: bool = true,
};

pub const RetryMessage = struct {
    failed_response: []const u8,
    error_message: []const u8,
};

pub const Completion = struct {
    text: []u8,
    raw_response: []u8,
    usage: Usage = .{},

    pub fn deinit(self: *Completion, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.raw_response);
        self.* = .{
            .text = &.{},
            .raw_response = &.{},
            .usage = .{},
        };
    }
};
