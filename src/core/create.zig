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

    const schema_json = try jsonschema.stringifyAlloc(T, temp_allocator, options.schema_options);
    defer temp_allocator.free(schema_json);

    const schema: types.StructuredSchema = .{
        .name = comptime jsonschema.schemaName(T, options.schema_options),
        .description = comptime jsonschema.schemaDescription(T),
        .schema_json = schema_json,
        .strict = true,
    };

    var attempt: usize = 0;
    while (attempt <= options.max_retries) : (attempt += 1) {
        var completion = try provider.completeStructured(temp_allocator, req, schema, options);
        defer completion.deinit(temp_allocator);

        if (usage_out) |usage| usage.add(completion.usage);

        var parse_check_arena = std.heap.ArenaAllocator.init(temp_allocator);
        defer parse_check_arena.deinit();

        _ = std.json.parseFromSliceLeaky(T, parse_check_arena.allocator(), completion.text, options.parse_options) catch |parse_err| {
            if (attempt == options.max_retries) return Error.MaxRetriesExceeded;

            const error_message = try std.fmt.allocPrint(
                temp_allocator,
                "JSON parsing failed: {s}. Return only valid JSON matching the schema.",
                .{@errorName(parse_err)},
            );
            defer temp_allocator.free(error_message);

            try provider.appendRetry(temp_allocator, &req, .{
                .failed_response = completion.text,
                .error_message = error_message,
            });
            continue;
        };

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

    const schema_json = try jsonschema.stringifyAlloc(T, temp_allocator, options.schema_options);
    defer temp_allocator.free(schema_json);

    const schema: types.StructuredSchema = .{
        .name = comptime jsonschema.schemaName(T, options.schema_options),
        .description = comptime jsonschema.schemaDescription(T),
        .schema_json = schema_json,
        .strict = true,
    };

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

        _ = std.json.parseFromSliceLeaky(T, parse_check_arena.allocator(), completion.text, options.parse_options) catch |parse_err| {
            const error_name = @errorName(parse_err);
            emit(hooks, .parse_error, .{
                .attempt = attempt,
                .schema_name = schema.name,
                .response_text = completion.text,
                .raw_response = completion.raw_response,
                .error_name = error_name,
                .usage = call_usage,
            });

            if (attempt == options.max_retries) return Error.MaxRetriesExceeded;

            const error_message = try std.fmt.allocPrint(
                temp_allocator,
                "JSON parsing failed: {s}. Return only valid JSON matching the schema.",
                .{error_name},
            );
            defer temp_allocator.free(error_message);

            try provider.appendRetry(temp_allocator, &req, .{
                .failed_response = completion.text,
                .error_message = error_message,
            });
            emit(hooks, .retry, .{
                .attempt = attempt,
                .schema_name = schema.name,
                .response_text = completion.text,
                .raw_response = completion.raw_response,
                .error_name = error_name,
                .usage = call_usage,
            });
            continue;
        };

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

fn emit(hooks: ?types.Hooks, event: types.HookEvent, info: types.HookInfo) void {
    if (hooks) |h| h.emit(event, info);
}

fn maybeDeinitRequest(provider: anytype, allocator: std.mem.Allocator, request: anytype) void {
    const Provider = util.DeclType(@TypeOf(provider));
    if (comptime @hasDecl(Provider, "deinitRequest")) {
        provider.deinitRequest(allocator, request);
    }
}
