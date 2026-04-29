const std = @import("std");
const jsonschema = @import("jsonschema");
const options_mod = @import("options.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub const Error = error{
    MaxRetriesExceeded,
    UnsupportedMode,
    MissingOutputText,
    InvalidProviderResponse,
};

pub fn createWithArena(
    comptime T: type,
    temp_allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    provider: anytype,
    request: anytype,
    usage_out: ?*types.Usage,
    comptime options: options_mod.Options,
) !T {
    var req = request;
    defer maybeDeinitRequest(provider, temp_allocator, &req);

    var schema = try schemaAlloc(T, temp_allocator, options.schema_options);
    defer schema.deinit(temp_allocator);

    var attempt: usize = 0;
    while (attempt <= options.max_retries) : (attempt += 1) {
        var completion = try provider.completeStructured(temp_allocator, req, schema, options);
        defer completion.deinit(temp_allocator);

        if (usage_out) |usage| usage.add(completion.usage);

        var parse_check_arena = std.heap.ArenaAllocator.init(temp_allocator);
        defer parse_check_arena.deinit();

        if (try checkParseAndValidate(T, parse_check_arena.allocator(), completion.text, options)) |failure| {
            if (attempt == options.max_retries) return Error.MaxRetriesExceeded;

            try provider.appendRetry(temp_allocator, &req, .{
                .failed_response = completion.text,
                .error_message = failure.message,
            });
            continue;
        }

        return std.json.parseFromSliceLeaky(T, result_allocator, completion.text, options.parse_options);
    }

    return Error.MaxRetriesExceeded;
}

pub fn createDetailedWithArena(
    comptime T: type,
    temp_allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    provider: anytype,
    request: anytype,
    usage_out: ?*types.Usage,
    hooks: ?types.Hooks,
    comptime options: options_mod.Options,
) !types.CreateResult(T) {
    var req = request;
    defer maybeDeinitRequest(provider, temp_allocator, &req);

    var schema = try schemaAlloc(T, temp_allocator, options.schema_options);
    defer schema.deinit(temp_allocator);

    emit(hooks, .request_start, .{ .schema_name = schema.name });

    var call_usage: types.Usage = .{};
    var attempt: usize = 0;
    while (attempt <= options.max_retries) : (attempt += 1) {
        var completion = try provider.completeStructured(temp_allocator, req, schema, options);
        defer completion.deinit(temp_allocator);

        call_usage.add(completion.usage);
        if (usage_out) |usage| usage.add(completion.usage);

        emit(hooks, .response_received, .{
            .attempt = attempt,
            .schema_name = schema.name,
            .response_text = completion.text,
            .raw_response = completion.raw_response,
            .usage = completion.usage,
        });

        var parse_check_arena = std.heap.ArenaAllocator.init(temp_allocator);
        defer parse_check_arena.deinit();

        if (try checkParseAndValidate(T, parse_check_arena.allocator(), completion.text, options)) |failure| {
            const event: types.HookEvent = switch (failure.kind) {
                .parse => .parse_error,
                .validation => .validation_error,
            };
            emit(hooks, event, .{
                .attempt = attempt,
                .schema_name = schema.name,
                .response_text = completion.text,
                .raw_response = completion.raw_response,
                .error_name = failure.error_name,
                .validation_errors = failure.validation_errors,
                .usage = call_usage,
            });

            if (attempt == options.max_retries) return Error.MaxRetriesExceeded;

            try provider.appendRetry(temp_allocator, &req, .{
                .failed_response = completion.text,
                .error_message = failure.message,
            });
            emit(hooks, .retry, .{
                .attempt = attempt,
                .schema_name = schema.name,
                .response_text = completion.text,
                .raw_response = completion.raw_response,
                .error_name = failure.error_name,
                .validation_errors = failure.validation_errors,
                .usage = call_usage,
            });
            continue;
        }

        const text = try result_allocator.dupe(u8, completion.text);
        errdefer result_allocator.free(text);
        const raw_response = try result_allocator.dupe(u8, completion.raw_response);
        errdefer result_allocator.free(raw_response);

        const value = try std.json.parseFromSliceLeaky(T, result_allocator, text, options.parse_options);

        emit(hooks, .completion_done, .{
            .attempt = attempt,
            .schema_name = schema.name,
            .response_text = text,
            .raw_response = raw_response,
            .usage = call_usage,
        });

        return .{
            .value = value,
            .text = text,
            .raw_response = raw_response,
            .usage = call_usage,
        };
    }

    return Error.MaxRetriesExceeded;
}

pub fn schemaAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    comptime schema_options: jsonschema.Options,
) !types.StructuredSchema {
    var tool = try jsonschema.toolSchemaAlloc(T, allocator, schema_options);
    errdefer tool.deinit(allocator);
    return .{
        .name = tool.name,
        .description = tool.description,
        .schema_json = tool.schema_json,
        .strict = true,
    };
}

const FailureKind = enum { parse, validation };

const CheckFailure = struct {
    kind: FailureKind,
    error_name: []const u8,
    message: []const u8,
    validation_errors: ?[]const u8 = null,
};

fn checkParseAndValidate(
    comptime T: type,
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime options: options_mod.Options,
) !?CheckFailure {
    const value = std.json.parseFromSliceLeaky(T, allocator, text, options.parse_options) catch |parse_err| {
        const error_name = @errorName(parse_err);
        return .{
            .kind = .parse,
            .error_name = error_name,
            .message = try std.fmt.allocPrint(
                allocator,
                "JSON parsing failed: {s}. Return only valid JSON matching the schema.",
                .{error_name},
            ),
        };
    };

    if (!options.validate) return null;

    var validation_output: std.Io.Writer.Allocating = .init(allocator);
    errdefer validation_output.deinit();

    if (try jsonschema.validateValue(T, value, &validation_output.writer, options.schema_options)) {
        validation_output.deinit();
        return null;
    }

    const validation_errors = try validation_output.toOwnedSlice();
    errdefer allocator.free(validation_errors);

    return .{
        .kind = .validation,
        .error_name = "ValidationError",
        .validation_errors = validation_errors,
        .message = try std.fmt.allocPrint(
            allocator,
            "JSON parsed but failed schema validation:\n{s}Return JSON matching the schema.",
            .{validation_errors},
        ),
    };
}

fn emit(hooks: ?types.Hooks, event: types.HookEvent, info: types.HookInfo) void {
    if (hooks) |h| h.emit(event, info);
}

fn maybeDeinitRequest(provider: anytype, allocator: std.mem.Allocator, request: anytype) void {
    const Provider = util.DeclType(@TypeOf(provider));
    if (comptime @hasDecl(Provider, "deinitRequest")) {
        provider.deinitRequest(allocator, request);
    }
}
