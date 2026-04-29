const std = @import("std");
const types = @import("../core/types.zig");
const Options = @import("../core/options.zig").Options;

pub const Request = struct {
    retry_count: usize = 0,
};

pub const Provider = struct {
    responses: []const []const u8,
    calls: usize = 0,
    retry_count: usize = 0,
    last_schema_name: ?[]const u8 = null,
    saw_parse_retry: bool = false,
    saw_validation_retry: bool = false,

    pub fn completeStructured(
        self: *Provider,
        allocator: std.mem.Allocator,
        request: Request,
        schema: types.StructuredSchema,
        comptime options: Options,
    ) !types.Completion {
        _ = options;
        self.last_schema_name = schema.name;

        if (self.responses.len == 0) return error.NoMockResponses;

        const index = if (self.calls < self.responses.len) self.calls else self.responses.len - 1;
        self.calls += 1;

        const text = self.responses[index];
        const raw = try std.fmt.allocPrint(
            allocator,
            "mock response {d}: {s}",
            .{ request.retry_count, text },
        );
        errdefer allocator.free(raw);

        return .{
            .text = try allocator.dupe(u8, text),
            .raw_response = raw,
            .usage = .{
                .input_tokens = 1,
                .output_tokens = 2,
                .total_tokens = 3,
            },
        };
    }

    pub fn appendRetry(
        self: *Provider,
        allocator: std.mem.Allocator,
        request: *Request,
        retry: types.RetryMessage,
    ) !void {
        _ = allocator;
        if (std.mem.indexOf(u8, retry.error_message, "JSON parsing failed") != null) {
            self.saw_parse_retry = true;
        }
        if (std.mem.indexOf(u8, retry.error_message, "failed schema validation") != null) {
            self.saw_validation_retry = true;
        }
        self.retry_count += 1;
        request.retry_count += 1;
    }
};
