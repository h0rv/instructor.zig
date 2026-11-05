//! SystemOne wire translation. Allocations, including failed parses, belong to
//! the caller's arena. Only native text questions and string choices are supported;
//! boolean/raw choice values and raw (including box) questions are rejected.
//! Score criteria always use objects, even for label-only levels. The normalized
//! SDK response is not the native response: unavailable usage details are zero.
const std = @import("std");
const api = @import("openai");
const decisions = @import("../decisions.zig");
const Usage = @import("../core/types.zig").Usage;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Decoded = struct { value: api.DecisionResponse, usage: Usage, rounding: ?u8 };

pub fn encode(allocator: Allocator, params: decisions.CreateParams) !Value {
    const model = params.model orelse return error.MissingModel;
    if (model.len == 0) return error.MissingModel;
    var root = std.json.ObjectMap.empty;
    try root.put(allocator, "model", .{ .string = model });
    try root.put(allocator, "state", .{ .string = params.input });
    try root.put(allocator, "questions", .{ .object = try encodeQuestions(allocator, params.questions) });
    return .{ .object = root };
}

fn questionName(question: api.QuestionParam) ![]const u8 {
    const name = switch (question) {
        .predicate => |q| q.name,
        .choice => |q| q.name,
        .score => |q| q.name,
        .raw => return error.UnsupportedDecisionQuestion,
    } orelse return error.InvalidDecisionQuestions;
    if (name.len == 0) return error.InvalidDecisionQuestions;
    return name;
}

fn encodeQuestions(allocator: Allocator, questions: []const api.QuestionParam) !std.json.ObjectMap {
    if (questions.len == 0 or questions.len > 400) return error.InvalidDecisionQuestions;
    var result = std.json.ObjectMap.empty;
    for (questions) |question| {
        const name = try questionName(question);
        if (result.contains(name)) return error.InvalidDecisionQuestions;
        var wire = std.json.ObjectMap.empty;
        switch (question) {
            .predicate => |q| {
                if (!std.mem.eql(u8, q.type, "predicate") or q.instructions != .string)
                    return error.UnsupportedDecisionQuestion;
                try wire.put(allocator, "type", .{ .string = "noul" });
                try wire.put(allocator, "instructions", .{ .string = q.instructions.string });
            },
            .choice => |q| {
                if (!std.mem.eql(u8, q.type, "choice") or q.instructions != .string)
                    return error.UnsupportedDecisionQuestion;
                if (q.choices.len == 0 or q.choices.len > 255) return error.InvalidDecisionQuestions;
                var criteria = std.json.ObjectMap.empty;
                for (q.choices) |choice| {
                    if (choice.value != .string) return error.UnsupportedDecisionQuestion;
                    const key = choice.value.string;
                    if (key.len == 0 or criteria.contains(key)) return error.InvalidDecisionQuestions;
                    try criteria.put(allocator, key, .{ .string = choice.description orelse key });
                }
                try wire.put(allocator, "type", .{ .string = "choice" });
                try wire.put(allocator, "instructions", .{ .string = q.instructions.string });
                try wire.put(allocator, "criteria", .{ .object = criteria });
            },
            .score => |q| {
                if (!std.mem.eql(u8, q.type, "score") or q.instructions != .string)
                    return error.UnsupportedDecisionQuestion;
                if (q.levels.len == 0 or q.levels.len > 10) return error.InvalidDecisionQuestions;
                var criteria = std.json.Array.init(allocator);
                for (q.levels) |level| {
                    if (level.label.len == 0) return error.InvalidDecisionQuestions;
                    var entry = std.json.ObjectMap.empty;
                    try entry.put(allocator, "label", .{ .string = level.label });
                    if (level.description) |description| try entry.put(allocator, "description", .{ .string = description });
                    try criteria.append(.{ .object = entry });
                }
                try wire.put(allocator, "type", .{ .string = "score" });
                try wire.put(allocator, "instructions", .{ .string = q.instructions.string });
                try wire.put(allocator, "criteria", .{ .array = criteria });
            },
            .raw => return error.UnsupportedDecisionQuestion,
        }
        try result.put(allocator, name, .{ .object = wire });
    }
    return result;
}

pub fn decode(allocator: Allocator, body: []const u8, questions: []const api.QuestionParam) !Decoded {
    const root = std.json.parseFromSliceLeaky(Value, allocator, body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidDecisionResponse;
    if (root != .object) return error.InvalidDecisionResponse;
    for ([_][]const u8{ "error", "detail", "error_type" }) |key| {
        if (root.object.get(key)) |value| if (value != .null) return error.ProviderHttpError;
    }
    const model = try string(try field(root, "model"));
    const answers = try field(root, "answers");
    if (answers != .object) return error.InvalidDecisionResponse;
    // Also validate raw create questions; do not silently interpret unsupported
    // native forms differently on the return path.
    const expected = try encodeQuestions(allocator, questions);
    if (answers.object.count() != questions.len) return error.InvalidDecisionResponse;
    const wire_usage = try field(root, "usage");
    const input = try unsigned(try field(wire_usage, "input_tokens"));
    const output = try unsigned(try field(wire_usage, "output_tokens"));
    const total = std.math.add(u64, input, output) catch return error.InvalidDecisionResponse;
    // The canonical generated SDK stores counts in signed 64-bit integers.
    if (total > std.math.maxInt(i64)) return error.InvalidDecisionResponse;
    const usage: Usage = .{ .input_tokens = input, .output_tokens = output, .total_tokens = total };
    var rounding: ?u8 = if (std.mem.indexOf(u8, model, "jev") != null) 2 else null;
    if (root.object.get("rounding")) |value| {
        const n = try unsigned(value);
        if (n > 15) return error.InvalidDecisionResponse;
        rounding = @intCast(n);
    }
    const normalized = try allocator.alloc(api.AnswerResource, questions.len);
    for (questions, normalized) |question, *answer| {
        const name = try questionName(question);
        const wire = answers.object.get(name) orelse return error.InvalidDecisionResponse;
        if (wire != .object) return error.InvalidDecisionResponse;
        if (wire.object.count() == 0) return error.DecisionDetailsUnavailable;
        const kind = try string(try field(wire, "type"));
        if (std.mem.eql(u8, kind, "refusal")) return error.Refusal;
        // Use the owned response key for names; no result borrows request data.
        const owned_name = answers.object.keys()[answers.object.getIndex(name).?];
        answer.* = switch (question) {
            .predicate => blk: {
                if (!std.mem.eql(u8, kind, "noul")) return error.InvalidDecisionResponse;
                break :blk .{ .predicate = .{
                    .name = owned_name,
                    .type = "predicate",
                    .probability = try probability(try field(wire, "noul")),
                } };
            },
            .choice => |q| blk: {
                if (!std.mem.eql(u8, kind, "choice")) return error.InvalidDecisionResponse;
                const selected = try string(try field(wire, "choice"));
                const confidence = try probability(wire.object.get("confidence") orelse return error.DecisionDetailsUnavailable);
                const distribution = try details(wire);
                if (distribution.count() != q.choices.len) return error.InvalidDecisionResponse;
                const criteria = expected.get(name).?.object.get("criteria").?.object;
                if (!criteria.contains(selected)) return error.InvalidDecisionResponse;
                const probabilities = try allocator.alloc(api.ChoiceProbabilityResource, distribution.count());
                for (distribution.keys(), distribution.values(), probabilities) |key, value, *out| {
                    if (!criteria.contains(key)) return error.InvalidDecisionResponse;
                    out.* = .{ .value = .{ .string = key }, .probability = try probability(value) };
                }
                break :blk .{ .choice = .{
                    .name = owned_name,
                    .type = "choice",
                    .choice = .{ .string = selected },
                    .confidence = confidence,
                    .probabilities = probabilities,
                } };
            },
            .score => |q| blk: {
                if (!std.mem.eql(u8, kind, "score")) return error.InvalidDecisionResponse;
                const score = try number(try field(wire, "score"));
                if (score < 0 or score > @as(f64, @floatFromInt(q.levels.len - 1))) return error.InvalidDecisionResponse;
                const confidence = try probability(wire.object.get("confidence") orelse return error.DecisionDetailsUnavailable);
                const distribution = try details(wire);
                const legend = try field(wire, "legend");
                if (legend != .object or legend.object.count() != q.levels.len or distribution.count() != q.levels.len)
                    return error.InvalidDecisionResponse;
                // Equal counts plus canonical in-range index keys ensure every
                // level occurs exactly once. JSON parsing already rejects duplicates.
                var legend_it = legend.object.iterator();
                while (legend_it.next()) |entry| {
                    const i = try index(entry.key_ptr.*, q.levels.len);
                    const level = q.levels[i];
                    const value = entry.value_ptr.*;
                    if (value != .object or value.object.count() != @as(usize, if (level.description != null) 2 else 1))
                        return error.InvalidDecisionResponse;
                    if (!std.mem.eql(u8, try string(try field(value, "label")), level.label)) return error.InvalidDecisionResponse;
                    if (level.description) |description| {
                        if (!std.mem.eql(u8, try string(try field(value, "description")), description)) return error.InvalidDecisionResponse;
                    }
                }
                const probabilities = try allocator.alloc(api.ScoreProbabilityResource, q.levels.len);
                for (distribution.keys(), distribution.values()) |key, value| {
                    const i = try index(key, q.levels.len);
                    const legend_entry = legend.object.get(key) orelse return error.InvalidDecisionResponse;
                    probabilities[i] = .{
                        .value = @intCast(i),
                        // Original label, never the description or formatted JSON.
                        .label = try string(try field(legend_entry, "label")),
                        .probability = try probability(value),
                    };
                }
                break :blk .{ .score = .{
                    .name = owned_name,
                    .type = "score",
                    .score = score,
                    .confidence = confidence,
                    .probabilities = probabilities,
                } };
            },
            .raw => return error.UnsupportedDecisionQuestion,
        };
    }
    return .{
        .value = .{
            .model = model,
            .answers = normalized,
            .usage = .{
                .input_tokens = @intCast(input),
                .output_tokens = @intCast(output),
                .total_tokens = @intCast(total),
                .input_tokens_details = .{ .cached_tokens = 0, .cache_write_tokens = 0 },
                .output_tokens_details = .{ .reasoning_tokens = 0 },
            },
        },
        .usage = usage,
        .rounding = rounding,
    };
}

fn field(value: Value, key: []const u8) !Value {
    if (value != .object) return error.InvalidDecisionResponse;
    return value.object.get(key) orelse error.InvalidDecisionResponse;
}

fn string(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidDecisionResponse;
}

fn number(value: Value) !f64 {
    const n: f64 = switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidDecisionResponse,
        else => return error.InvalidDecisionResponse,
    };
    return if (std.math.isFinite(n)) n else error.InvalidDecisionResponse;
}

fn probability(value: Value) !f64 {
    const n = try number(value);
    return if (n >= 0 and n <= 1) n else error.InvalidDecisionResponse;
}

fn unsigned(value: Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidDecisionResponse,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.InvalidDecisionResponse,
        else => error.InvalidDecisionResponse,
    };
}

fn index(key: []const u8, count: usize) !usize {
    if (key.len == 0 or (key.len > 1 and key[0] == '0')) return error.InvalidDecisionResponse;
    for (key) |c| if (c < '0' or c > '9') return error.InvalidDecisionResponse;
    const n = std.fmt.parseInt(usize, key, 10) catch return error.InvalidDecisionResponse;
    return if (n < count) n else error.InvalidDecisionResponse;
}

fn details(wire: Value) !std.json.ObjectMap {
    const distribution = wire.object.get("probabilities") orelse return error.DecisionDetailsUnavailable;
    if (distribution != .object) return error.InvalidDecisionResponse;
    if (distribution.object.count() == 0) return error.DecisionDetailsUnavailable;
    return distribution.object;
}

const testing = std.testing;
const test_questions: []const api.QuestionParam = &.{
    .{ .predicate = .{ .name = "p", .type = "predicate", .instructions = .{ .string = "True?" } } },
    .{ .choice = .{ .name = "c", .type = "choice", .instructions = .{ .string = "Pick" }, .choices = &.{
        .{ .value = .{ .string = "yes" }, .description = "Accept" },
        .{ .value = .{ .string = "no" } },
    } } },
    .{ .score = .{ .name = "s", .type = "score", .instructions = .{ .string = "Rate" }, .levels = &.{
        .{ .label = "low" }, .{ .label = "high", .description = "Urgent" },
    } } },
};
const test_body =
    \\{"model":"typesafe/jev-latest","answers":{"s":{"type":"score","score":0.73,"confidence":0.63,"probabilities":{"1":0.73,"0":0.27},"legend":{"1":{"description":"Urgent","label":"high"},"0":{"label":"low"}}},"p":{"type":"noul","noul":0.9},"c":{"type":"choice","choice":"yes","confidence":0.81,"probabilities":{"no":0.2,"yes":0.8}}},"usage":{"input_tokens":9,"output_tokens":3}}
;

// Helpers use a caller arena so both successful and failing paths are leak checked.
fn decodePredicateFixture(allocator: Allocator, answer: []const u8, suffix: []const u8) !Decoded {
    const body = try allocator.print("{{\"model\":\"other\",\"answers\":{{\"p\":{s}}},{s}}}", .{ answer, suffix });
    return decode(allocator, body, test_questions[0..1]);
}

test "SystemOne encodes native text with exact criteria descriptions and labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const wire = try encode(arena.allocator(), .{ .model = "jev-latest", .input = "source", .questions = test_questions });
    try testing.expectEqualStrings("source", wire.object.get("state").?.string);
    const questions = wire.object.get("questions").?.object;
    try testing.expectEqualStrings("noul", questions.get("p").?.object.get("type").?.string);
    const criteria = questions.get("c").?.object.get("criteria").?.object;
    try testing.expectEqualStrings("Accept", criteria.get("yes").?.string);
    try testing.expectEqualStrings("no", criteria.get("no").?.string);
    const levels = questions.get("s").?.object.get("criteria").?.array.items;
    try testing.expectEqualStrings("low", levels[0].object.get("label").?.string);
    try testing.expect(levels[0].object.get("description") == null);
    try testing.expectEqualStrings("high", levels[1].object.get("label").?.string);
    try testing.expectEqualStrings("Urgent", levels[1].object.get("description").?.string);
}

test "SystemOne rejects unsupported native raw box boolean choices and nontext instructions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw: api.QuestionParam = .{ .raw = .{ .object = .empty } };
    try testing.expectError(error.UnsupportedDecisionQuestion, encode(a, .{ .model = "jev", .input = "", .questions = &.{raw} }));
    var q = test_questions[1];
    q.choice.choices = &.{ .{ .value = .{ .boolean = true } }, .{ .value = .{ .string = "true" } } };
    try testing.expectError(error.UnsupportedDecisionQuestion, encode(a, .{ .model = "jev", .input = "", .questions = &.{q} }));
    q = test_questions[0];
    q.predicate.instructions = .{ .raw = .{ .string = "True?" } };
    try testing.expectError(error.UnsupportedDecisionQuestion, encode(a, .{ .model = "jev", .input = "", .questions = &.{q} }));
    q = test_questions[0];
    q.predicate.type = "box";
    try testing.expectError(error.UnsupportedDecisionQuestion, encode(a, .{ .model = "jev", .input = "", .questions = &.{q} }));
}

test "SystemOne rejects absent empty duplicate names and choice keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]?[]const u8{ null, "" }) |name| {
        var q = test_questions[0];
        q.predicate.name = name;
        try testing.expectError(error.InvalidDecisionQuestions, encode(a, .{ .model = "jev", .input = "", .questions = &.{q} }));
    }
    try testing.expectError(error.InvalidDecisionQuestions, encode(a, .{ .model = "jev", .input = "", .questions = &.{ test_questions[0], test_questions[0] } }));
    var q = test_questions[1];
    q.choice.choices = &.{ .{ .value = .{ .string = "same" } }, .{ .value = .{ .string = "same" } } };
    try testing.expectError(error.InvalidDecisionQuestions, encode(a, .{ .model = "jev", .input = "", .questions = &.{q} }));
}

test "SystemOne reorders named answers and preserves all reported scores confidence and probabilities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), test_body, test_questions);
    try testing.expectEqualStrings("p", decoded.value.answers[0].predicate.name.?);
    try testing.expectEqual(@as(f64, 0.9), decoded.value.answers[0].predicate.probability);
    try testing.expectEqualStrings("yes", decoded.value.answers[1].choice.choice.string);
    try testing.expectEqual(@as(f64, 0.81), decoded.value.answers[1].choice.confidence);
    try testing.expectEqual(@as(f64, 0.73), decoded.value.answers[2].score.score);
    try testing.expectEqual(@as(f64, 0.63), decoded.value.answers[2].score.confidence);
    try testing.expectEqualStrings("high", decoded.value.answers[2].score.probabilities[1].label);
    try testing.expectEqual(@as(f64, 0.73), decoded.value.answers[2].score.probabilities[1].probability);
    try testing.expectEqual(@as(u64, 12), decoded.usage.total_tokens);
    try testing.expectEqual(@as(i64, 12), decoded.value.usage.total_tokens);
    try testing.expectEqual(@as(i64, 0), decoded.value.usage.input_tokens_details.cached_tokens);
    try testing.expectEqual(@as(?u8, 2), decoded.rounding);
}

test "SystemOne rejects provider envelopes duplicate JSON missing extra and mismatched answers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"error\":{}}", "{\"detail\":\"bad\"}", "{\"error_type\":\"bad\"}" }) |body|
        try testing.expectError(error.ProviderHttpError, decode(a, body, test_questions));
    for ([_][]const u8{
        "{",                                "[]",                                                    "{\"model\":\"a\",\"model\":\"b\"}",
        "{\"model\":\"a\",\"answers\":{}}", "{\"model\":\"a\",\"answers\":{\"extra\":{},\"p\":{}}}",
    }) |body| try testing.expectError(error.InvalidDecisionResponse, decode(a, body, test_questions[0..1]));
    const usage = "\"usage\":{\"input_tokens\":1,\"output_tokens\":2}";
    try testing.expectError(error.InvalidDecisionResponse, decodePredicateFixture(a, "{\"type\":\"choice\"}", usage));
    try testing.expectError(error.InvalidDecisionResponse, decodePredicateFixture(a, "{\"type\":\"noul\",\"noul\":0.5,\"noul\":0.7}", usage));
    try testing.expectError(error.Refusal, decodePredicateFixture(a, "{\"type\":\"refusal\"}", usage));
    try testing.expectError(error.DecisionDetailsUnavailable, decodePredicateFixture(a, "{}", usage));
}

test "SystemOne requires explicit unsigned usage and bounded finite probabilities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "\"usage\":{}",                                                         "\"usage\":{\"input_tokens\":1}",
        "\"usage\":{\"input_tokens\":-1,\"output_tokens\":2}",                  "\"usage\":{\"input_tokens\":1.5,\"output_tokens\":2}",
        "\"usage\":{\"input_tokens\":\"1\",\"output_tokens\":2}",               "\"usage\":{\"input_tokens\":18446744073709551615,\"output_tokens\":1}",
        "\"usage\":{\"input_tokens\":9223372036854775807,\"output_tokens\":1}",
    }) |suffix| try testing.expectError(error.InvalidDecisionResponse, decodePredicateFixture(a, "{\"type\":\"noul\",\"noul\":0.9}", suffix));
    for ([_][]const u8{ "-0.1", "1.1", "1e999", "null", "\"0.9\"" }) |n| {
        const answer = try a.print("{{\"type\":\"noul\",\"noul\":{s}}}", .{n});
        try testing.expectError(error.InvalidDecisionResponse, decodePredicateFixture(a, answer, "\"usage\":{\"input_tokens\":1,\"output_tokens\":2}"));
    }
}

test "SystemOne rounding requires integer zero through fifteen and does not guess other models" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const answer = "{\"type\":\"noul\",\"noul\":1}";
    const usage = "\"usage\":{\"input_tokens\":0,\"output_tokens\":0}";
    try testing.expectEqual(@as(?u8, null), (try decodePredicateFixture(a, answer, usage)).rounding);
    try testing.expectEqual(@as(?u8, 0), (try decodePredicateFixture(a, answer, usage ++ ",\"rounding\":0")).rounding);
    try testing.expectEqual(@as(?u8, 15), (try decodePredicateFixture(a, answer, usage ++ ",\"rounding\":15")).rounding);
    for ([_][]const u8{ "-1", "16", "2.5", "null", "\"2\"" }) |n| {
        const suffix = try a.print("{s},\"rounding\":{s}", .{ usage, n });
        try testing.expectError(error.InvalidDecisionResponse, decodePredicateFixture(a, answer, suffix));
    }
}

fn decodeModifiedFixture(allocator: Allocator, name: []const u8, wire_answer: []const u8) !Decoded {
    var root = try std.json.parseFromSliceLeaky(Value, allocator, test_body, .{ .allocate = .alloc_always });
    const answer = try std.json.parseFromSliceLeaky(Value, allocator, wire_answer, .{ .allocate = .alloc_always });
    try root.object.getPtr("answers").?.object.put(allocator, name, answer);
    return decode(allocator, try std.json.Stringify.valueAlloc(allocator, root, .{}), test_questions);
}

test "SystemOne never fabricates missing choice or score details including empty-map sentinels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"type\":\"choice\",\"choice\":\"yes\"}",
        "{\"type\":\"choice\",\"choice\":\"yes\",\"confidence\":0.8}",
        "{\"type\":\"choice\",\"choice\":\"yes\",\"confidence\":0.8,\"probabilities\":{}}",
    }) |answer| try testing.expectError(error.DecisionDetailsUnavailable, decodeModifiedFixture(a, "c", answer));
    for ([_][]const u8{
        "{\"type\":\"score\",\"score\":0.7}",
        "{\"type\":\"score\",\"score\":0.7,\"confidence\":0.8}",
        "{\"type\":\"score\",\"score\":0.7,\"confidence\":0.8,\"probabilities\":{}}",
    }) |answer| try testing.expectError(error.DecisionDetailsUnavailable, decodeModifiedFixture(a, "s", answer));
}

test "SystemOne requires canonical complete score indices exact object legend and valid choice keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"0\":0.2}",            "{\"00\":0.2,\"1\":0.8}", "{\"+0\":0.2,\"1\":0.8}",
        "{\"-1\":0.2,\"1\":0.8}", "{\"0\":0.2,\"2\":0.8}",  "{\"0\":-0.2,\"1\":0.8}",
    }) |distribution| {
        const answer = try a.print("{{\"type\":\"score\",\"score\":0.8,\"confidence\":0.7,\"probabilities\":{s},\"legend\":{{\"0\":{{\"label\":\"low\"}},\"1\":{{\"label\":\"high\",\"description\":\"Urgent\"}}}}}}", .{distribution});
        try testing.expectError(error.InvalidDecisionResponse, decodeModifiedFixture(a, "s", answer));
    }
    for ([_][]const u8{
        "{\"0\":\"low\",\"1\":{\"label\":\"high\",\"description\":\"Urgent\"}}",
        "{\"0\":{\"label\":\"wrong\"},\"1\":{\"label\":\"high\",\"description\":\"Urgent\"}}",
        "{\"0\":{\"label\":\"low\"},\"1\":{\"label\":\"high\"}}",
        "{\"00\":{\"label\":\"low\"},\"1\":{\"label\":\"high\",\"description\":\"Urgent\"}}",
    }) |legend| {
        const answer = try a.print("{{\"type\":\"score\",\"score\":0.8,\"confidence\":0.7,\"probabilities\":{{\"0\":0.2,\"1\":0.8}},\"legend\":{s}}}", .{legend});
        try testing.expectError(error.InvalidDecisionResponse, decodeModifiedFixture(a, "s", answer));
    }
    for ([_][]const u8{
        "{\"type\":\"choice\",\"choice\":\"yes\",\"confidence\":1.1,\"probabilities\":{\"yes\":0.8,\"no\":0.2}}",
        "{\"type\":\"choice\",\"choice\":\"yes\",\"confidence\":0.8,\"probabilities\":{\"yes\":0.8,\"extra\":0.2}}",
        "{\"type\":\"choice\",\"choice\":\"other\",\"confidence\":0.8,\"probabilities\":{\"yes\":0.8,\"no\":0.2}}",
    }) |answer| try testing.expectError(error.InvalidDecisionResponse, decodeModifiedFixture(a, "c", answer));
}

fn allocationFailures(backing: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = try encode(arena.allocator(), .{ .model = "jev", .input = "source", .questions = test_questions });
    _ = try decode(arena.allocator(), test_body, test_questions);
}

test "SystemOne caller arena owns allocations on success and OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
}
