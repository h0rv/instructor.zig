const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const QueryParam = struct { name: []const u8, value: []const u8 };
pub const Api = enum { responses, chat_completions, anthropic, decisions, system_one };

// All helpers allocate into a caller-owned arena. Partial results on failure
// are reclaimed by that arena, including recursively allocated JSON values.
pub fn cloneExtraBody(allocator: Allocator, extra: ?Value) !?Value {
    const value = extra orelse return null;
    if (value != .object) return error.InvalidExtraBody;
    return try cloneValue(allocator, value);
}

fn cloneValue(allocator: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        .array => |items| blk: {
            var result: Value = .{ .array = .init(allocator) };
            for (items.items) |item| try result.array.append(try cloneValue(allocator, item));
            break :blk result;
        },
        .object => |fields| blk: {
            var result: Value = .{ .object = .empty };
            var it = fields.iterator();
            while (it.next()) |entry| try result.object.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*));
            break :blk result;
        },
        else => value,
    };
}

pub fn mergeExtraBody(allocator: Allocator, defaults: ?Value, overrides: ?Value) !?Value {
    if (defaults) |value| if (value != .object) return error.InvalidExtraBody;
    if (overrides) |value| if (value != .object) return error.InvalidExtraBody;
    if (defaults) |base| return if (overrides) |extra| try mergeValues(allocator, base, extra) else try cloneValue(allocator, base);
    return cloneExtraBody(allocator, overrides);
}

fn mergeValues(allocator: Allocator, base: Value, extra: Value) Allocator.Error!Value {
    if (base != .object or extra != .object) return cloneValue(allocator, extra);
    var result = try cloneValue(allocator, base);
    var it = extra.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = if (result.object.get(key)) |previous|
            try mergeValues(allocator, previous, entry.value_ptr.*)
        else
            try cloneValue(allocator, entry.value_ptr.*);
        try result.object.put(allocator, try allocator.dupe(u8, key), value);
    }
    return result;
}

pub fn cloneQuery(allocator: Allocator, query: []const QueryParam) ![]const QueryParam {
    const result = try allocator.alloc(QueryParam, query.len);
    for (result, query) |*out, entry| out.* = .{
        .name = try allocator.dupe(u8, entry.name),
        .value = try allocator.dupe(u8, entry.value),
    };
    return result;
}

/// Raw names are compared before encoding. Repeated override entries survive.
/// Strings may be borrowed for the duration of the request.
pub fn mergeQuery(allocator: Allocator, defaults: []const QueryParam, overrides: []const QueryParam) ![]const QueryParam {
    var result: std.ArrayList(QueryParam) = .empty;
    outer: for (defaults) |entry| {
        for (overrides) |override| if (std.mem.eql(u8, entry.name, override.name)) continue :outer;
        try result.append(allocator, entry);
    }
    try result.appendSlice(allocator, overrides);
    return result.toOwnedSlice(allocator);
}

fn validateExtra(extra: Value, api: Api, structured: bool) !void {
    if (extra != .object) return error.InvalidExtraBody;
    var it = extra.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        for ([_][]const u8{ "model", "input", "messages" }) |reserved| {
            if (std.mem.eql(u8, key, reserved)) return error.ReservedBodyField;
        }
        if ((api == .decisions or api == .system_one) and std.mem.eql(u8, key, "questions")) return error.ReservedBodyField;
        if (api == .system_one and std.mem.eql(u8, key, "state")) return error.ReservedBodyField;
        if (std.mem.eql(u8, key, "stream")) {
            if (value != .bool or value.bool) return error.UnsupportedStreaming;
        }
        if (!structured) continue;
        for ([_][]const u8{ "tools", "tool_choice" }) |reserved| {
            if (std.mem.eql(u8, key, reserved)) return error.ReservedBodyField;
        }
        switch (api) {
            .decisions, .system_one => {},
            .chat_completions => {
                if (std.mem.eql(u8, key, "response_format")) return error.ReservedBodyField;
            },
            .responses, .anthropic => {
                const container = if (api == .responses) "text" else "output_config";
                if (std.mem.eql(u8, key, container)) {
                    // Replacing this ancestor would also replace its format.
                    if (value != .object or value.object.contains("format")) return error.ReservedBodyField;
                }
            },
        }
    }
}

/// Generated request structs are serialized once, then merged as JSON objects.
/// Never use the generated extra_body serializer: it emits duplicate members.
pub fn mergePayload(allocator: Allocator, base: anytype, extra: ?Value, api: Api, structured: bool) !Value {
    if (extra) |value| try validateExtra(value, api, structured);
    const value = if (@TypeOf(base) == Value)
        base
    else blk: {
        const encoded = try std.json.Stringify.valueAlloc(allocator, base, .{ .emit_null_optional_fields = false });
        break :blk try std.json.parseFromSliceLeaky(Value, allocator, encoded, .{ .parse_numbers = false });
    };
    return if (extra) |overrides| try mergeValues(allocator, value, overrides) else try cloneValue(allocator, value);
}

pub fn validateHeader(header: std.http.Header) !void {
    // Body framing belongs to the HTTP implementation, not request extras.
    if (std.ascii.eqlIgnoreCase(header.name, "content-length") or
        std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) return error.ReservedHeader;
    if (header.name.len == 0) return error.InvalidHeader;
    for (header.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeader;
    }
    for (header.value) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0 or byte == 127 or (byte < 32 and byte != '\t')) return error.InvalidHeader;
    }
}

/// Last value wins case-insensitively, retaining the winning caller's casing.
pub fn mergeHeaders(allocator: Allocator, defaults: []const std.http.Header, overrides: []const std.http.Header) ![]const std.http.Header {
    var result: std.ArrayList(std.http.Header) = .empty;
    for ([_][]const std.http.Header{ defaults, overrides }) |headers| {
        for (headers) |header| {
            try validateHeader(header);
            var index: usize = 0;
            while (index < result.items.len) {
                if (std.ascii.eqlIgnoreCase(result.items[index].name, header.name)) {
                    _ = result.orderedRemove(index);
                } else index += 1;
            }
            try result.append(allocator, header);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Insert the endpoint before any existing base query or fragment.
pub fn endpointUrl(allocator: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    const end = std.mem.indexOfAny(u8, base, "?#") orelse base.len;
    return allocator.print("{s}{s}{s}", .{ std.mem.trimEnd(u8, base[0..end], "/"), path, base[end..] });
}

pub fn appendQuery(allocator: Allocator, url: []const u8, query: []const QueryParam) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(allocator, url[0..end]);
    var has_query = std.mem.indexOfScalar(u8, url[0..end], '?') != null;
    for (query) |entry| {
        const last = if (result.items.len == 0) 0 else result.items[result.items.len - 1];
        if (!has_query) {
            try result.append(allocator, '?');
            has_query = true;
        } else if (last != '?' and last != '&') try result.append(allocator, '&');
        try appendEncoded(allocator, &result, entry.name);
        try result.append(allocator, '=');
        try appendEncoded(allocator, &result, entry.value);
    }
    try result.appendSlice(allocator, url[end..]);
    return result.toOwnedSlice(allocator);
}

fn appendEncoded(allocator: Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) {
            try output.append(allocator, byte);
        } else try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
}

test "request options deep clone and merge retain arbitrary precision and replace arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = try std.json.parseFromSliceLeaky(Value, a,
        \\{"nested":{"a":1,"replace":[1,2]},"large":1.2345678901234567890123456789e+100}
    , .{ .parse_numbers = false });
    const extra = try std.json.parseFromSliceLeaky(Value, a, "{\"nested\":{\"b\":2,\"replace\":[3]}}", .{});
    const cloned = (try cloneExtraBody(a, defaults)).?;
    try std.testing.expect(cloned.object.get("large").?.number_string.ptr != defaults.object.get("large").?.number_string.ptr);
    const merged = (try mergeExtraBody(a, defaults, extra)).?;
    const nested = merged.object.get("nested").?.object;
    try std.testing.expect(nested.contains("a") and nested.contains("b"));
    try std.testing.expectEqual(@as(usize, 1), nested.get("replace").?.array.items.len);
    try std.testing.expectEqualStrings("1.2345678901234567890123456789e+100", merged.object.get("large").?.number_string);
    try std.testing.expectError(error.InvalidExtraBody, cloneExtraBody(a, .null));
    try std.testing.expectError(error.InvalidExtraBody, mergeExtraBody(a, defaults, .{ .integer = 2 }));
}

test "request options query raw override names repeated values and RFC3986 escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = [_]QueryParam{ .{ .name = "x", .value = "old" }, .{ .name = "x", .value = "old2" }, .{ .name = "%78", .value = "raw" } };
    const cloned = try cloneQuery(a, &defaults);
    try std.testing.expect(cloned[0].name.ptr != defaults[0].name.ptr);
    const merged = try mergeQuery(a, cloned, &.{ .{ .name = "x", .value = "a b&/#?+" }, .{ .name = "x", .value = "é" } });
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    const url = try appendQuery(a, "https://example.test/p?old=1#frag", merged);
    try std.testing.expectEqualStrings("https://example.test/p?old=1&%2578=raw&x=a%20b%26%2F%23%3F%2B&x=%C3%A9#frag", url);
    try std.testing.expectEqualStrings("https://example.test/v1/messages?old=1#frag", try endpointUrl(a, "https://example.test/?old=1#frag", "/v1/messages"));
}

test "request options reserve only envelope and schema owned paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.json.parseFromSliceLeaky(Value, a, "{\"text\":{\"format\":{\"type\":\"json_schema\"}}}", .{});
    inline for (.{ "{\"model\":\"other\"}", "{\"input\":[]}", "{\"messages\":[]}" }) |json| {
        const extra = try std.json.parseFromSliceLeaky(Value, a, json, .{});
        try std.testing.expectError(error.ReservedBodyField, mergePayload(a, base, extra, .responses, false));
    }
    inline for (.{ "{\"text\":null}", "{\"text\":{\"format\":{}}}", "{\"tools\":[]}", "{\"tool_choice\":null}" }) |json| {
        const extra = try std.json.parseFromSliceLeaky(Value, a, json, .{});
        try std.testing.expectError(error.ReservedBodyField, mergePayload(a, base, extra, .responses, true));
        _ = try mergePayload(a, base, extra, .responses, false);
    }
    inline for (.{ "{\"output_config\":3}", "{\"output_config\":{\"format\":{}}}" }) |json| {
        const extra = try std.json.parseFromSliceLeaky(Value, a, json, .{});
        try std.testing.expectError(error.ReservedBodyField, mergePayload(a, base, extra, .anthropic, true));
        _ = try mergePayload(a, base, extra, .responses, true);
    }
    const chat_format = try std.json.parseFromSliceLeaky(Value, a, "{\"response_format\":{}}", .{});
    try std.testing.expectError(error.ReservedBodyField, mergePayload(a, base, chat_format, .chat_completions, true));
    _ = try mergePayload(a, base, chat_format, .anthropic, true);
    _ = try mergePayload(a, base, chat_format, .responses, true);
    const allowed = try std.json.parseFromSliceLeaky(Value, a, "{\"text\":{\"verbosity\":\"low\"},\"output_config\":{\"effort\":\"high\"},\"unknown\":{\"model\":1,\"format\":2},\"stream\":false}", .{});
    const merged = try mergePayload(a, base, allowed, .responses, true);
    try std.testing.expect(merged.object.get("text").?.object.contains("format"));
    try std.testing.expect(merged.object.get("text").?.object.contains("verbosity"));
    inline for (.{ "{\"stream\":true}", "{\"stream\":null}", "{\"stream\":\"false\"}" }) |json| {
        const extra = try std.json.parseFromSliceLeaky(Value, a, json, .{});
        try std.testing.expectError(error.UnsupportedStreaming, mergePayload(a, base, extra, .responses, false));
    }
}

test "decisions extras protect questions and allow unknown configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.json.parseFromSliceLeaky(Value, a, "{\"model\":\"gpt-6-luna\",\"input\":\"text\",\"questions\":[]}", .{});
    inline for (.{ false, true }) |structured| {
        inline for (.{ "{\"questions\":[]}", "{\"questions\":null}", "{\"model\":\"other\"}", "{\"input\":\"other\"}" }) |json| {
            const extra = try std.json.parseFromSliceLeaky(Value, a, json, .{});
            try std.testing.expectError(error.ReservedBodyField, mergePayload(a, base, extra, .decisions, structured));
        }
        const extra = try std.json.parseFromSliceLeaky(Value, a, "{\"safety_identifier\":\"user\",\"prompt_cache_options\":{\"future\":true},\"unknown\":{\"questions\":42}}", .{});
        const merged = try mergePayload(a, base, extra, .decisions, structured);
        try std.testing.expectEqualStrings("user", merged.object.get("safety_identifier").?.string);
        try std.testing.expect(merged.object.get("prompt_cache_options").?.object.get("future").?.bool);
        try std.testing.expectEqual(@as(i64, 42), merged.object.get("unknown").?.object.get("questions").?.integer);
    }
}

test "request options headers validate injection and retain winning casing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const headers = try mergeHeaders(arena.allocator(), &.{ .{ .name = "Authorization", .value = "old" }, .{ .name = "AUTHORIZATION", .value = "old2" } }, &.{.{ .name = "aUtHoRiZaTiOn", .value = "new" }});
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("aUtHoRiZaTiOn", headers[0].name);
    try std.testing.expectEqualStrings("new", headers[0].value);
    inline for (.{ "", "bad name", "bad:name", "bad\r\n" }) |name| try std.testing.expectError(error.InvalidHeader, validateHeader(.{ .name = name, .value = "ok" }));
    try std.testing.expectError(error.InvalidHeader, validateHeader(.{ .name = "okay", .value = "value\r\nx-injected: yes" }));
    try std.testing.expectError(error.ReservedHeader, validateHeader(.{ .name = "Content-Length", .value = "0" }));
    try std.testing.expectError(error.ReservedHeader, validateHeader(.{ .name = "Transfer-Encoding", .value = "chunked" }));
}

fn allocationExercise(allocator: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.json.parseFromSliceLeaky(Value, a, "{\"nested\":{\"list\":[1,2]},\"large\":1e100}", .{ .parse_numbers = false });
    const extra = try cloneExtraBody(a, base);
    _ = try mergeExtraBody(a, base, extra);
    _ = try mergePayload(a, .{ .temperature = @as(f64, 0.5) }, extra, .responses, true);
    const query = try cloneQuery(a, &.{.{ .name = "x y", .value = "a&b" }});
    const merged = try mergeQuery(a, query, &.{.{ .name = "x y", .value = "new" }});
    _ = try appendQuery(a, "https://example.test?old=1#f", merged);
    _ = try mergeHeaders(a, &.{.{ .name = "Authorization", .value = "old" }}, &.{.{ .name = "AUTHORIZATION", .value = "new" }});
}

test "request options all allocation failures clean up through caller arena" {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), allocationExercise, .{});
}
