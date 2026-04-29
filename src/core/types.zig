const std = @import("std");

pub const Mode = enum {
    json_schema,
    json_object,
    tool_call,
    tool_call_required,
    responses_tool_call,
    responses_tool_call_required,
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

    pub fn deinit(self: *StructuredSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.schema_json);
        self.* = .{ .name = "", .schema_json = &.{} };
    }
};

pub const RetryMessage = struct {
    failed_response: []const u8,
    error_message: []const u8,
};

pub fn CreateResult(comptime T: type) type {
    return struct {
        value: T,
        text: []const u8,
        raw_response: []const u8,
        usage: Usage = .{},
    };
}

pub const HookEvent = enum {
    request_start,
    response_received,
    parse_error,
    validation_error,
    retry,
    completion_done,
};

pub const HookInfo = struct {
    attempt: usize = 0,
    schema_name: ?[]const u8 = null,
    response_text: ?[]const u8 = null,
    raw_response: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    validation_errors: ?[]const u8 = null,
    usage: Usage = .{},
};

pub const HookFn = *const fn (ctx: ?*anyopaque, event: HookEvent, info: HookInfo) void;

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    on_event: ?HookFn = null,

    pub fn emit(self: Hooks, event: HookEvent, info: HookInfo) void {
        if (self.on_event) |on_event| on_event(self.ctx, event, info);
    }
};

pub const Diagnostic = struct {
    provider: []const u8 = "unknown",
    status: ?std.http.Status = null,
    body: ?[]const u8 = null,

    pub fn writeError(self: Diagnostic, writer: *std.Io.Writer, err: anyerror) !void {
        try writer.print("error: {s}\n", .{@errorName(err)});
        try writer.print("provider: {s}\n", .{self.provider});
        if (self.status) |status| {
            try writer.print("status: {d} {s}\n", .{
                @intFromEnum(status),
                status.phrase() orelse @tagName(status),
            });
        }
        if (self.body) |body| {
            const trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (trimmed.len != 0) {
                const max_body_len = 4096;
                const shown = trimmed[0..@min(trimmed.len, max_body_len)];
                try writer.print("body: {s}\n", .{shown});
                if (trimmed.len > max_body_len) {
                    try writer.print("body_truncated: {} bytes omitted\n", .{trimmed.len - max_body_len});
                }
            }
        }
    }
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
