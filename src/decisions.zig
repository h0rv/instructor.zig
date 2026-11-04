//! Typed Decisions questions and strict decoding. Distributions and provider
//! confidence are returned as reported, not as claims of calibrated correctness.
//! Question strings borrow caller memory; built questions belong to the caller's
//! arena. Decoded score distributions borrow the response's memory.
const std = @import("std");
const api = @import("openai");
const Allocator = std.mem.Allocator;
const Usage = @import("core/types.zig").Usage;
const QueryParam = @import("request_options.zig").QueryParam;

pub const Scale = struct { minimum: f64, maximum: f64 };
pub const BoolQuestion = struct { instructions: []const u8, threshold: f64 = 0.5 };
pub const PredicateQuestion = struct { instructions: []const u8 };
pub const ScoreLevel = struct { label: []const u8, description: ?[]const u8 = null };
pub const ScoreQuestion = struct {
    instructions: []const u8,
    levels: []const ScoreLevel,
    scale: ?Scale = null,
};
pub const FloatQuestion = union(enum) { predicate: PredicateQuestion, score: ScoreQuestion };

pub fn ChoiceDescription(comptime E: type) type {
    requireEnum(E);
    return struct { value: E, description: []const u8 };
}

pub fn EnumQuestion(comptime E: type) type {
    requireEnum(E);
    return struct {
        instructions: []const u8,
        descriptions: []const ChoiceDescription(E) = &.{},
    };
}

pub fn Question(comptime T: type) type {
    requireScalar(T);
    return switch (@typeInfo(T)) {
        .bool => BoolQuestion,
        .@"enum" => EnumQuestion(T),
        .float => FloatQuestion,
        else => unreachable,
    };
}

pub const PredicateDetails = struct { probability: f64 };
pub fn ChoiceDetails(comptime E: type) type {
    requireEnum(E);
    return struct { probabilities: std.EnumArray(E, f64), confidence: f64 };
}
pub const ScoreDetails = struct {
    /// Provider weighted level index, before any user scale is applied.
    score: f64,
    probabilities: []const api.ScoreProbabilityResource,
    confidence: f64,
};
pub const FloatDetails = union(enum) { predicate: PredicateDetails, score: ScoreDetails };

fn ScalarDetails(comptime T: type) type {
    requireScalar(T);
    return switch (@typeInfo(T)) {
        .bool => PredicateDetails,
        .@"enum" => ChoiceDetails(T),
        .float => FloatDetails,
        else => unreachable,
    };
}

fn QuestionFields(comptime T: type) type {
    return Mirrored(T, .questions);
}

pub const InputParams = struct {
    input: []const u8,
    model: ?[]const u8 = null,
    extra_body: ?std.json.Value = null,
    extra_headers: []const std.http.Header = &.{},
    extra_query: []const QueryParam = &.{},
};

/// Borrows the client and question strings. Initialization makes no request.
pub fn Questions(comptime T: type) type {
    const Fields = QuestionFields(T);
    return struct {
        resource: @import("client.zig").Decisions,
        fields: Fields,

        pub fn init(client: *const @import("client.zig").Client, fields: Fields) @This() {
            return .{ .resource = client.decisions, .fields = fields };
        }

        /// Return the fixed-size value and free the response.
        pub fn parse(self: @This(), params: InputParams) !T {
            var result = try self.parseDetailed(params);
            defer result.deinit();
            return result.value;
        }

        /// Keep probabilities and response data until the result is deinitialized.
        pub fn parseDetailed(self: @This(), params: InputParams) !Parsed(T) {
            return self.resource.parse(T, .{
                .input = params.input,
                .questions = self.fields,
                .model = params.model,
                .extra_body = params.extra_body,
                .extra_headers = params.extra_headers,
                .extra_query = params.extra_query,
            });
        }
    };
}

pub fn Details(comptime T: type) type {
    return Mirrored(T, .details);
}

fn Mirrored(comptime T: type, comptime kind: enum { questions, details }) type {
    requireOutput(T);
    if (@typeInfo(T) != .@"struct") return if (kind == .questions) Question(T) else ScalarDetails(T);
    const info = @typeInfo(T).@"struct";
    var types: [info.field_names.len]type = undefined;
    for (&types, info.field_types) |*out, field_type| {
        out.* = if (kind == .questions) Question(field_type) else ScalarDetails(field_type);
    }
    return @Struct(.auto, null, info.field_names, &types, &@splat(.{}));
}

fn requireEnum(comptime T: type) void {
    @setEvalBranchQuota(20_000);
    if (@typeInfo(T) != .@"enum") @compileError("Decisions choices require an exhaustive enum");
    const info = @typeInfo(T).@"enum";
    if (info.mode != .exhaustive) @compileError("Decisions does not support nonexhaustive enums");
    if (info.field_names.len < 2 or info.field_names.len > 255)
        @compileError("Decisions enums require 2..255 choices");
    inline for (info.field_names) |name| if (name.len == 0) @compileError("Decisions enum choice names must be nonempty");
}

fn requireScalar(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool => {},
        .@"enum" => requireEnum(T),
        .float => if (T != f32 and T != f64) {
            @compileError("Decisions floats must be f32 or f64");
        },
        else => @compileError("Decisions supports only bool, exhaustive enums, f32/f64, or a flat nonempty struct of these; no strings, integers, nested objects, optionals, or unions"),
    }
}

fn requireOutput(comptime T: type) void {
    @setEvalBranchQuota(20_000);
    if (@typeInfo(T) == .@"struct") {
        const info = @typeInfo(T).@"struct";
        if (info.is_tuple or info.field_names.len == 0 or info.field_names.len > 400)
            @compileError("Decisions output must be a named flat struct with 1..400 fields");
        inline for (info.field_names, info.field_types, info.field_attrs) |name, field_type, attrs| {
            if (name.len == 0 or attrs.@"comptime") @compileError("Decisions fields require nonempty names and runtime values");
            requireScalar(field_type);
        }
    } else requireScalar(T);
}

fn Params(comptime Q: type) type {
    return struct {
        input: []const u8,
        questions: Q,
        model: ?[]const u8 = null,
        extra_body: ?std.json.Value = null,
        extra_headers: []const std.http.Header = &.{},
        extra_query: []const QueryParam = &.{},
    };
}

pub const ConditionParams = struct {
    input: []const u8,
    instructions: []const u8,
    threshold: f64 = 0.5,
    model: ?[]const u8 = null,
    extra_body: ?std.json.Value = null,
    extra_headers: []const std.http.Header = &.{},
    extra_query: []const QueryParam = &.{},
};

pub const CreateParams = Params([]const api.QuestionParam);
pub fn ParseParams(comptime T: type) type {
    return Params(QuestionFields(T));
}

/// Single owner. Do not deinit copies after transferring ownership.
pub const Response = struct {
    arena: *std.heap.ArenaAllocator,
    value: api.DecisionResponse,
    status: std.http.Status = .ok,
    raw_response: []const u8,
    usage: Usage,
    model: []const u8,

    pub fn deinit(self: *Response) void {
        destroyArena(self.arena);
        self.* = undefined;
    }
};

/// All borrowed details and response data live until this owner's deinit.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,
        details: Details(T),
        response: api.DecisionResponse,
        status: std.http.Status = .ok,
        raw_response: []const u8,
        usage: Usage,
        model: []const u8,

        pub fn deinit(self: *@This()) void {
            destroyArena(self.arena);
            self.* = undefined;
        }
    };
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const backing = arena.child_allocator;
    arena.deinit();
    backing.destroy(arena);
}

fn count(comptime T: type) usize {
    requireOutput(T);
    return if (@typeInfo(T) == .@"struct") @typeInfo(T).@"struct".field_names.len else 1;
}

fn unitInterval(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn validateScalar(comptime T: type, question: Question(T)) !void {
    switch (@typeInfo(T)) {
        .bool => {
            if (question.instructions.len == 0) return error.EmptyInstructions;
            if (!unitInterval(question.threshold)) return error.InvalidThreshold;
        },
        .@"enum" => {
            if (question.instructions.len == 0) return error.EmptyInstructions;
            var seen = std.EnumArray(T, bool).initFill(false);
            for (question.descriptions) |description| {
                if (description.description.len == 0) return error.EmptyChoiceDescription;
                if (seen.get(description.value)) return error.DuplicateChoiceDescription;
                seen.set(description.value, true);
            }
        },
        .float => switch (question) {
            .predicate => |predicate| if (predicate.instructions.len == 0) return error.EmptyInstructions,
            .score => |score| {
                if (score.instructions.len == 0) return error.EmptyInstructions;
                if (score.levels.len < 2 or score.levels.len > 10) return error.InvalidScoreLevelCount;
                for (score.levels) |level| if (level.label.len == 0) return error.EmptyScoreLabel;
                if (score.scale) |scale| {
                    if (!std.math.isFinite(scale.minimum) or !std.math.isFinite(scale.maximum) or scale.minimum >= scale.maximum)
                        return error.InvalidScale;
                }
            },
        },
        else => unreachable,
    }
}

fn validateQuestions(comptime T: type, questions: QuestionFields(T)) !void {
    if (@typeInfo(T) == .@"struct") {
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
            try validateScalar(F, @field(questions, name));
        }
    } else try validateScalar(T, questions);
}

/// The allocator must be a caller-owned arena, including on allocation failure.
/// Instructions, descriptions and levels are borrowed for the request lifetime.
pub fn buildQuestions(comptime T: type, allocator: Allocator, questions: QuestionFields(T)) ![]const api.QuestionParam {
    try validateQuestions(T, questions);
    const result = try allocator.alloc(api.QuestionParam, count(T));
    if (@typeInfo(T) == .@"struct") {
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |name, F, i| {
            result[i] = try buildScalar(F, allocator, name, @field(questions, name));
        }
    } else result[0] = try buildScalar(T, allocator, "decision", questions);
    return result;
}

fn buildScalar(comptime T: type, allocator: Allocator, name: []const u8, question: Question(T)) !api.QuestionParam {
    return switch (@typeInfo(T)) {
        .bool => .{ .predicate = .{ .instructions = .{ .string = question.instructions }, .name = name, .type = "predicate" } },
        .@"enum" => blk: {
            const names = @typeInfo(T).@"enum".field_names;
            const choices = try allocator.alloc(api.ChoiceOptionParam, names.len);
            inline for (names, 0..) |tag, i| {
                choices[i] = .{ .value = .{ .string = tag } };
                for (question.descriptions) |description| {
                    if (description.value == @field(T, tag)) choices[i].description = description.description;
                }
            }
            break :blk .{ .choice = .{ .instructions = .{ .string = question.instructions }, .name = name, .type = "choice", .choices = choices } };
        },
        .float => switch (question) {
            .predicate => |p| .{ .predicate = .{ .instructions = .{ .string = p.instructions }, .name = name, .type = "predicate" } },
            .score => |s| blk: {
                const levels = try allocator.alloc(api.ScoreLevelParam, s.levels.len);
                for (levels, s.levels) |*out, level| out.* = .{ .label = level.label, .description = level.description };
                break :blk .{ .score = .{ .instructions = .{ .string = s.instructions }, .name = name, .type = "score", .levels = levels } };
            },
        },
        else => unreachable,
    };
}

const probability_tolerance = 1e-3;

/// All answers must match in order. No partial result or default is returned.
/// This performs no allocations and does not parse generated text.
pub fn decode(comptime T: type, response: api.DecisionResponse, questions: QuestionFields(T)) !struct { value: T, details: Details(T) } {
    try validateQuestions(T, questions);
    if (response.answers.len != count(T)) return error.InvalidDecisionResponse;
    if (@typeInfo(T) == .@"struct") {
        var value: T = undefined;
        var details: Details(T) = undefined;
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |name, F, i| {
            try validateName(response.answers[i], name);
            const result = try decodeScalar(F, response.answers[i], @field(questions, name));
            @field(value, name) = result.value;
            @field(details, name) = result.details;
        }
        return .{ .value = value, .details = details };
    } else {
        try validateName(response.answers[0], "decision");
        const result = try decodeScalar(T, response.answers[0], questions);
        return .{ .value = result.value, .details = result.details };
    }
}

fn validateName(answer: api.AnswerResource, expected: []const u8) !void {
    const name = switch (answer) {
        .predicate => |a| a.name,
        .choice => |a| a.name,
        .score => |a| a.name,
        .refusal => |a| blk: {
            if (!std.mem.eql(u8, a.type, "refusal")) return error.InvalidDecisionResponse;
            break :blk a.name;
        },
        .raw => return error.InvalidDecisionResponse,
    } orelse return error.InvalidDecisionResponse;
    if (!std.mem.eql(u8, name, expected)) return error.InvalidDecisionResponse;
    if (answer == .refusal) return error.Refusal;
}

fn predicateProbability(answer: api.AnswerResource) !f64 {
    const p = switch (answer) {
        .predicate => |p| p,
        else => return error.InvalidDecisionResponse,
    };
    if (!std.mem.eql(u8, p.type, "predicate") or !unitInterval(p.probability)) return error.InvalidDecisionResponse;
    return p.probability;
}

fn choiceValue(comptime E: type, value: api.ChoiceValueResource) !E {
    return switch (value) {
        .string => |s| std.meta.stringToEnum(E, s) orelse error.InvalidDecisionResponse,
        else => error.InvalidDecisionResponse,
    };
}

fn decodeScalar(comptime T: type, answer: api.AnswerResource, question: Question(T)) !struct { value: T, details: ScalarDetails(T) } {
    switch (@typeInfo(T)) {
        .bool => {
            const p = try predicateProbability(answer);
            return .{ .value = p >= question.threshold, .details = .{ .probability = p } };
        },
        .@"enum" => {
            const a = switch (answer) {
                .choice => |a| a,
                else => return error.InvalidDecisionResponse,
            };
            if (!std.mem.eql(u8, a.type, "choice") or !unitInterval(a.confidence) or a.probabilities.len != @typeInfo(T).@"enum".field_names.len)
                return error.InvalidDecisionResponse;
            const selected = try choiceValue(T, a.choice);
            var probabilities = std.EnumArray(T, f64).initUndefined();
            var seen = std.EnumArray(T, bool).initFill(false);
            var sum: f64 = 0;
            var maximum: f64 = 0;
            for (a.probabilities) |entry| {
                const key = try choiceValue(T, entry.value);
                if (seen.get(key) or !unitInterval(entry.probability)) return error.InvalidDecisionResponse;
                seen.set(key, true);
                probabilities.set(key, entry.probability);
                sum += entry.probability;
                maximum = @max(maximum, entry.probability);
            }
            if (@abs(sum - 1) > probability_tolerance or probabilities.get(selected) != maximum) return error.InvalidDecisionResponse;
            return .{ .value = selected, .details = .{ .probabilities = probabilities, .confidence = a.confidence } };
        },
        .float => switch (question) {
            .predicate => {
                const p = try predicateProbability(answer);
                return .{ .value = try narrow(T, p, 0, 1), .details = .{ .predicate = .{ .probability = p } } };
            },
            .score => |score_question| {
                const a = switch (answer) {
                    .score => |a| a,
                    else => return error.InvalidDecisionResponse,
                };
                const n = score_question.levels.len;
                const last: f64 = @floatFromInt(n - 1);
                if (!std.mem.eql(u8, a.type, "score") or !unitInterval(a.confidence) or a.probabilities.len != n or
                    !std.math.isFinite(a.score) or a.score < 0 or a.score > last) return error.InvalidDecisionResponse;
                var seen: [10]bool = @splat(false);
                var sum: f64 = 0;
                var weighted: f64 = 0;
                for (a.probabilities) |entry| {
                    if (entry.value < 0 or entry.value >= n or !unitInterval(entry.probability)) return error.InvalidDecisionResponse;
                    const i: usize = @intCast(entry.value);
                    if (seen[i] or !std.mem.eql(u8, entry.label, score_question.levels[i].label)) return error.InvalidDecisionResponse;
                    seen[i] = true;
                    sum += entry.probability;
                    weighted += @as(f64, @floatFromInt(i)) * entry.probability;
                }
                // Allow small differences from the provider's wire rounding.
                if (@abs(sum - 1) > probability_tolerance or @abs(a.score - weighted) > probability_tolerance)
                    return error.InvalidDecisionResponse;
                const value = if (score_question.scale) |scale| blk: {
                    const t = a.score / last;
                    // Convex interpolation avoids overflowing maximum - minimum.
                    const scaled = (1 - t) * scale.minimum + t * scale.maximum;
                    break :blk try narrow(T, scaled, scale.minimum, scale.maximum);
                } else try narrow(T, a.score, 0, last);
                return .{ .value = value, .details = .{ .score = .{ .score = a.score, .probabilities = a.probabilities, .confidence = a.confidence } } };
            },
        },
        else => unreachable,
    }
}

fn narrow(comptime T: type, value: f64, minimum: f64, maximum: f64) !T {
    if (!std.math.isFinite(value) or value < minimum or value > maximum) return error.InvalidDecisionResponse;
    const result: T = @floatCast(value);
    if (!std.math.isFinite(result)) return error.InvalidDecisionResponse;
    const widened: f64 = result;
    if (widened < minimum or widened > maximum) return error.InvalidDecisionResponse;
    return result;
}

const testing = std.testing;
const TestChoice = enum(i16) { @"not a match" = -7, @"send.review" = 11, @"日本語" = 327 };
const test_levels: []const ScoreLevel = &.{ .{ .label = "low" }, .{ .label = "medium", .description = "The middle level" }, .{ .label = "high" } };
const test_score_question: FloatQuestion = .{ .score = .{ .instructions = "Assess severity", .levels = test_levels } };

fn testResponse(answers: []const api.AnswerResource) api.DecisionResponse {
    return .{
        .answers = answers,
        .model = "gpt-6-luna",
        .usage = .{
            .input_tokens = 0,
            .output_tokens = 0,
            .total_tokens = 0,
            .input_tokens_details = .{ .cached_tokens = 0, .cache_write_tokens = 0 },
            .output_tokens_details = .{ .reasoning_tokens = 0 },
        },
    };
}

fn testPredicate(p: f64) api.AnswerResource {
    return .{ .predicate = .{ .name = "decision", .type = "predicate", .probability = p } };
}

fn testChoice() api.AnswerResource {
    return .{ .choice = .{
        .name = "decision",
        .type = "choice",
        .choice = .{ .string = "send.review" },
        .confidence = 0.91,
        .probabilities = &.{
            .{ .value = .{ .string = "not a match" }, .probability = 0.2 },
            .{ .value = .{ .string = "send.review" }, .probability = 0.6 },
            .{ .value = .{ .string = "日本語" }, .probability = 0.2 },
        },
    } };
}

fn testScore() api.AnswerResource {
    return .{ .score = .{
        .name = "decision",
        .type = "score",
        .score = 1,
        .confidence = 0.77,
        .probabilities = &.{
            .{ .value = 0, .label = "low", .probability = 0.25 },
            .{ .value = 1, .label = "medium", .probability = 0.5 },
            .{ .value = 2, .label = "high", .probability = 0.25 },
        },
    } };
}

fn expectInvalidChoice(answer: api.AnswerResource) !void {
    try testing.expectError(error.InvalidDecisionResponse, decode(TestChoice, testResponse(&.{answer}), .{ .instructions = "Choose" }));
}

fn expectInvalidScore(answer: api.AnswerResource) !void {
    try testing.expectError(error.InvalidDecisionResponse, decode(f64, testResponse(&.{answer}), test_score_question));
}

test "bool build uses generated instruction wrapper and explicit wire type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var instructions = [_]u8{ 'Y', 'e', 's', '?' };
    instructions[0] = 'y';
    const questions = try buildQuestions(bool, arena.allocator(), .{ .instructions = &instructions });
    try testing.expectEqual(@as(usize, 1), questions.len);
    try testing.expectEqualStrings("decision", questions[0].predicate.name.?);
    try testing.expectEqualStrings("predicate", questions[0].predicate.type);
    try testing.expectEqualStrings("yes?", questions[0].predicate.instructions.string);
    const result = try decode(bool, testResponse(&.{testPredicate(0.5)}), .{ .instructions = "Yes?" });
    try testing.expect(result.value);
    try testing.expectEqual(@as(f64, 0.5), result.details.probability);
    try testing.expect(!(try decode(bool, testResponse(&.{testPredicate(0.5)}), .{ .instructions = "Yes?", .threshold = 0.6 })).value);
    try testing.expect((try decode(bool, testResponse(&.{testPredicate(0)}), .{ .instructions = "Yes?", .threshold = 0 })).value);
    try testing.expect((try decode(bool, testResponse(&.{testPredicate(1)}), .{ .instructions = "Yes?", .threshold = 1 })).value);
}

test "enum wire choices use exact tag names and optional partial descriptions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const questions = try buildQuestions(TestChoice, arena.allocator(), .{
        .instructions = "Route this",
        .descriptions = &.{.{ .value = .@"send.review", .description = "Ask a reviewer" }},
    });
    const q = questions[0].choice;
    try testing.expectEqualStrings("choice", q.type);
    try testing.expectEqualStrings("decision", q.name.?);
    try testing.expectEqualStrings("Route this", q.instructions.string);
    try testing.expectEqual(@as(usize, 3), q.choices.len);
    try testing.expectEqualStrings("not a match", q.choices[0].value.string);
    try testing.expectEqualStrings("send.review", q.choices[1].value.string);
    try testing.expectEqualStrings("日本語", q.choices[2].value.string);
    try testing.expectEqualStrings("Ask a reviewer", q.choices[1].description.?);
    try testing.expect(q.choices[0].description == null and q.choices[2].description == null);
    const result = try decode(TestChoice, testResponse(&.{testChoice()}), .{ .instructions = "Route this" });
    try testing.expectEqual(TestChoice.@"send.review", result.value);
    try testing.expectEqual(@as(f64, 0.6), result.details.probabilities.get(.@"send.review"));
    try testing.expectEqual(@as(f64, 0.91), result.details.confidence);
}

test "floats explicitly select predicate or score and affine scale preserves raw details" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const predicate: FloatQuestion = .{ .predicate = .{ .instructions = "Is relevant?" } };
    const built_predicate = try buildQuestions(f32, arena.allocator(), predicate);
    try testing.expectEqualStrings("predicate", built_predicate[0].predicate.type);
    const p = try decode(f32, testResponse(&.{testPredicate(0.75)}), predicate);
    try testing.expectEqual(@as(f32, 0.75), p.value);
    try testing.expectEqual(@as(f64, 0.75), p.details.predicate.probability);
    const score_q: FloatQuestion = .{ .score = .{ .instructions = "Score", .levels = test_levels, .scale = .{ .minimum = -10, .maximum = 30 } } };
    const built_score = try buildQuestions(f64, arena.allocator(), score_q);
    try testing.expectEqualStrings("score", built_score[0].score.type);
    try testing.expectEqualStrings("Score", built_score[0].score.instructions.string);
    try testing.expectEqualStrings("The middle level", built_score[0].score.levels[1].description.?);
    const response = testResponse(&.{testScore()});
    const score = try decode(f64, response, score_q);
    try testing.expectEqual(@as(f64, 10), score.value);
    try testing.expectEqual(@as(f64, 1), score.details.score.score);
    try testing.expectEqual(@as(f64, 0.77), score.details.score.confidence);
    try testing.expect(score.details.score.probabilities.ptr == response.answers[0].score.probabilities.ptr);
    try testing.expectEqual(@as(f64, 1), (try decode(f64, response, test_score_question)).value);
}

test "flat struct mirrors exact field names and decodes all supported kinds" {
    const Output = struct { approved: bool, @"route.kind": TestChoice, relevance: f32, severity: f64 };
    const questions: QuestionFields(Output) = .{
        .approved = .{ .instructions = "Approve?" },
        .@"route.kind" = .{ .instructions = "Route" },
        .relevance = .{ .predicate = .{ .instructions = "Relevant?" } },
        .severity = test_score_question,
    };
    comptime {
        for (@typeInfo(Output).@"struct".field_names, @typeInfo(QuestionFields(Output)).@"struct".field_names, @typeInfo(Details(Output)).@"struct".field_names) |a, b, c| {
            if (!std.mem.eql(u8, a, b) or !std.mem.eql(u8, a, c)) @compileError("Field names changed");
        }
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try buildQuestions(Output, arena.allocator(), questions);
    try testing.expectEqual(@as(usize, 4), built.len);
    try testing.expectEqualStrings("approved", built[0].predicate.name.?);
    try testing.expectEqualStrings("route.kind", built[1].choice.name.?);
    try testing.expectEqualStrings("relevance", built[2].predicate.name.?);
    try testing.expectEqualStrings("severity", built[3].score.name.?);
    var answers = [_]api.AnswerResource{ testPredicate(0.9), testChoice(), testPredicate(0.25), testScore() };
    answers[0].predicate.name = "approved";
    answers[1].choice.name = "route.kind";
    answers[2].predicate.name = "relevance";
    answers[3].score.name = "severity";
    const parsed = try decode(Output, testResponse(&answers), questions);
    try testing.expect(parsed.value.approved);
    try testing.expectEqual(TestChoice.@"send.review", parsed.value.@"route.kind");
    try testing.expectEqual(@as(f32, 0.25), parsed.value.relevance);
    try testing.expectEqual(@as(f64, 1), parsed.value.severity);
    try testing.expectEqual(@as(f64, 0.25), parsed.details.relevance.predicate.probability);
    try testing.expectEqual(@as(f64, 0.77), parsed.details.severity.score.confidence);
}

test "question validation happens before allocation and before decoding" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    const response = testResponse(&.{testPredicate(0.5)});
    try testing.expectError(error.EmptyInstructions, buildQuestions(bool, allocator, .{ .instructions = "" }));
    try testing.expectError(error.EmptyInstructions, decode(bool, response, .{ .instructions = "" }));
    for ([_]f64{ -0.1, 1.1, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |threshold| {
        const q: BoolQuestion = .{ .instructions = "Yes?", .threshold = threshold };
        try testing.expectError(error.InvalidThreshold, buildQuestions(bool, allocator, q));
        try testing.expectError(error.InvalidThreshold, decode(bool, response, q));
    }
    try testing.expectError(error.EmptyInstructions, buildQuestions(TestChoice, allocator, .{ .instructions = "" }));
    const duplicate: EnumQuestion(TestChoice) = .{ .instructions = "Choose", .descriptions = &.{
        .{ .value = .@"send.review", .description = "First" },
        .{ .value = .@"send.review", .description = "Second" },
    } };
    try testing.expectError(error.DuplicateChoiceDescription, buildQuestions(TestChoice, allocator, duplicate));
    try testing.expectError(error.DuplicateChoiceDescription, decode(TestChoice, testResponse(&.{testChoice()}), duplicate));
    const empty: EnumQuestion(TestChoice) = .{ .instructions = "Choose", .descriptions = &.{.{ .value = .@"日本語", .description = "" }} };
    try testing.expectError(error.EmptyChoiceDescription, buildQuestions(TestChoice, allocator, empty));
    try testing.expectError(error.EmptyChoiceDescription, decode(TestChoice, testResponse(&.{testChoice()}), empty));
    try testing.expectError(error.EmptyInstructions, buildQuestions(f64, allocator, .{ .predicate = .{ .instructions = "" } }));
    try testing.expectError(error.EmptyInstructions, decode(f64, response, .{ .predicate = .{ .instructions = "" } }));
    var q = test_score_question;
    q.score.instructions = "";
    try testing.expectError(error.EmptyInstructions, buildQuestions(f64, allocator, q));
    try testing.expectError(error.EmptyInstructions, decode(f64, testResponse(&.{testScore()}), q));
    for ([_][]const ScoreLevel{ &.{}, &.{.{ .label = "Only" }}, &@as([11]ScoreLevel, @splat(.{ .label = "Too many" })) }) |levels| {
        q = test_score_question;
        q.score.levels = levels;
        try testing.expectError(error.InvalidScoreLevelCount, buildQuestions(f64, allocator, q));
        try testing.expectError(error.InvalidScoreLevelCount, decode(f64, testResponse(&.{testScore()}), q));
    }
    q = test_score_question;
    q.score.levels = &.{ .{ .label = "" }, .{ .label = "High" } };
    try testing.expectError(error.EmptyScoreLabel, buildQuestions(f64, allocator, q));
    try testing.expectError(error.EmptyScoreLabel, decode(f64, testResponse(&.{testScore()}), q));
    for ([_]Scale{
        .{ .minimum = 0, .maximum = 0 },
        .{ .minimum = 2, .maximum = 1 },
        .{ .minimum = std.math.nan(f64), .maximum = 1 },
        .{ .minimum = 0, .maximum = std.math.nan(f64) },
        .{ .minimum = -std.math.inf(f64), .maximum = 1 },
        .{ .minimum = 0, .maximum = std.math.inf(f64) },
    }) |scale| {
        q = test_score_question;
        q.score.scale = scale;
        try testing.expectError(error.InvalidScale, buildQuestions(f64, allocator, q));
        try testing.expectError(error.InvalidScale, decode(f64, testResponse(&.{testScore()}), q));
    }
    try testing.expect(!failing.has_induced_failure);
}

test "answer count names order duplicates refusal and raw fallback are rejected" {
    const q: BoolQuestion = .{ .instructions = "Yes?" };
    try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{}), q));
    try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{ testPredicate(1), testPredicate(0) }), q));
    var a = testPredicate(0.5);
    for ([_]?[]const u8{ null, "", "unknown" }) |name| {
        a.predicate.name = name;
        try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{a}), q));
    }
    const refusal: api.AnswerResource = .{ .refusal = .{ .name = "decision", .type = "refusal" } };
    try testing.expectError(error.Refusal, decode(bool, testResponse(&.{refusal}), q));
    try testing.expectError(error.Refusal, decode(TestChoice, testResponse(&.{refusal}), .{ .instructions = "Choose" }));
    try testing.expectError(error.Refusal, decode(f64, testResponse(&.{refusal}), test_score_question));
    var bad_refusal = refusal;
    bad_refusal.refusal.type = "predicate";
    try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{bad_refusal}), q));
    const raw: api.AnswerResource = .{ .raw = .{ .string = "true" } };
    try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{raw}), q));
    try expectInvalidChoice(raw);
    try expectInvalidScore(raw);
    const Output = struct { first: bool, second: bool };
    const questions: QuestionFields(Output) = .{ .first = q, .second = q };
    var answers = [_]api.AnswerResource{ testPredicate(0.8), testPredicate(0.2) };
    answers[0].predicate.name = "first";
    answers[1].predicate.name = "first";
    try testing.expectError(error.InvalidDecisionResponse, decode(Output, testResponse(&answers), questions));
    answers[0].predicate.name = "second";
    try testing.expectError(error.InvalidDecisionResponse, decode(Output, testResponse(&answers), questions));
    answers[0].predicate.name = "first";
    answers[1] = .{ .refusal = .{ .name = "second", .type = "refusal" } };
    try testing.expectError(error.Refusal, decode(Output, testResponse(&answers), questions));
}

test "predicate requires exact answer type and finite bounded probability" {
    const q: BoolQuestion = .{ .instructions = "Yes?" };
    const fq: FloatQuestion = .{ .predicate = .{ .instructions = "Probability?" } };
    for ([_]f64{ -0.001, 1.001, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |p| {
        try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{testPredicate(p)}), q));
        try testing.expectError(error.InvalidDecisionResponse, decode(f32, testResponse(&.{testPredicate(p)}), fq));
    }
    var answer = testPredicate(0.5);
    answer.predicate.type = "score";
    try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{answer}), q));
    try testing.expectError(error.InvalidDecisionResponse, decode(bool, testResponse(&.{testChoice()}), q));
    try testing.expectError(error.InvalidDecisionResponse, decode(f64, testResponse(&.{testScore()}), fq));
    try expectInvalidChoice(testPredicate(0.5));
    try expectInvalidScore(testPredicate(0.5));
    try expectInvalidChoice(testScore());
    try expectInvalidScore(testChoice());
}

test "choice distributions must be complete unique finite normalized and select a maximum" {
    var a = testChoice();
    var distribution: [3]api.ChoiceProbabilityResource = a.choice.probabilities[0..3].*;
    a.choice.probabilities = &distribution;
    a.choice.type = "score";
    try expectInvalidChoice(a);
    a.choice.type = "choice";
    for ([_]api.ChoiceValueResource{ .{ .string = "unknown" }, .{ .boolean = true }, .{ .raw = .{ .string = "send.review" } } }) |choice| {
        a.choice.choice = choice;
        try expectInvalidChoice(a);
    }
    a.choice.choice = .{ .string = "not a match" };
    try expectInvalidChoice(a);
    a.choice.choice = .{ .string = "send.review" };
    for ([_]f64{ -0.1, 1.1, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        a.choice.confidence = bad;
        try expectInvalidChoice(a);
        a.choice.confidence = 0.9;
        distribution[0].probability = bad;
        try expectInvalidChoice(a);
        distribution[0].probability = 0.2;
    }
    a.choice.probabilities = distribution[0..2];
    try expectInvalidChoice(a);
    a.choice.probabilities = &distribution;
    const original = distribution[0];
    for ([_]api.ChoiceValueResource{ .{ .string = "unknown" }, .{ .boolean = false }, .{ .raw = .{ .string = "not a match" } }, .{ .string = "send.review" } }) |bad| {
        distribution[0].value = bad;
        try expectInvalidChoice(a);
    }
    distribution[0] = original;
    distribution[0].probability = 0.1;
    try expectInvalidChoice(a);
    distribution[0].probability = 0.2005;
    _ = try decode(TestChoice, testResponse(&.{a}), .{ .instructions = "Choose" });
    distribution[0].probability = 0.202;
    try expectInvalidChoice(a);
    distribution[0].probability = 0.5;
    distribution[1].probability = 0.5;
    distribution[2].probability = 0;
    const tied = try decode(TestChoice, testResponse(&.{a}), .{ .instructions = "Choose" });
    try testing.expectEqual(TestChoice.@"send.review", tied.value);
    a.choice.choice = .{ .string = "not a match" };
    _ = try decode(TestChoice, testResponse(&.{a}), .{ .instructions = "Choose" });
}

test "score distributions require complete unique indices matching labels and weighted consistency" {
    var a = testScore();
    var distribution: [3]api.ScoreProbabilityResource = a.score.probabilities[0..3].*;
    a.score.probabilities = &distribution;
    a.score.type = "predicate";
    try expectInvalidScore(a);
    a.score.type = "score";
    for ([_]f64{ -0.001, 2.001, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |score| {
        a.score.score = score;
        try expectInvalidScore(a);
    }
    a.score.score = 1.01;
    try expectInvalidScore(a);
    a.score.score = 1.0005;
    _ = try decode(f64, testResponse(&.{a}), test_score_question);
    a.score.score = 1;
    for ([_]f64{ -0.1, 1.1, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        a.score.confidence = bad;
        try expectInvalidScore(a);
        a.score.confidence = 0.7;
        distribution[0].probability = bad;
        try expectInvalidScore(a);
        distribution[0].probability = 0.25;
    }
    a.score.probabilities = distribution[0..2];
    try expectInvalidScore(a);
    a.score.probabilities = &distribution;
    for ([_]i64{ -1, 1, 3, std.math.maxInt(i64) }) |bad| {
        distribution[0].value = bad;
        try expectInvalidScore(a);
    }
    distribution[0].value = 0;
    distribution[0].label = "medium";
    try expectInvalidScore(a);
    distribution[0].label = "low";
    distribution[0].probability = 0.1;
    try expectInvalidScore(a);
    distribution[0].probability = 0.2505;
    _ = try decode(f64, testResponse(&.{a}), test_score_question);
    distribution[0].probability = 0.252;
    try expectInvalidScore(a);
    distribution[0].probability = 0.25;
    std.mem.swap(api.ScoreProbabilityResource, &distribution[0], &distribution[2]);
    _ = try decode(f64, testResponse(&.{a}), test_score_question);
}

test "score scaling stays finite bounded and rejects overflowing f32 narrowing" {
    var answer = testScore();
    var probabilities: [3]api.ScoreProbabilityResource = answer.score.probabilities[0..3].*;
    answer.score.probabilities = &probabilities;
    var question = test_score_question;
    question.score.scale = .{ .minimum = -std.math.floatMax(f64), .maximum = std.math.floatMax(f64) };
    const midpoint = try decode(f64, testResponse(&.{answer}), question);
    try testing.expectEqual(@as(f64, 0), midpoint.value);
    for ([_]usize{ 0, 1, 2 }) |index| {
        for (&probabilities, 0..) |*entry, i| entry.probability = if (i == index) 1 else 0;
        answer.score.score = @floatFromInt(index);
        const decoded = try decode(f64, testResponse(&.{answer}), question);
        try testing.expect(std.math.isFinite(decoded.value));
        try testing.expect(decoded.value >= question.score.scale.?.minimum and decoded.value <= question.score.scale.?.maximum);
        if (index != 1) try testing.expectError(error.InvalidDecisionResponse, decode(f32, testResponse(&.{answer}), question));
    }
    question.score.scale = .{ .minimum = 0, .maximum = 100 };
    try testing.expectEqual(@as(f32, 100), (try decode(f32, testResponse(&.{answer}), question)).value);
    question.score.scale = .{ .minimum = 0, .maximum = 0.1 };
    try testing.expectError(error.InvalidDecisionResponse, decode(f32, testResponse(&.{answer}), question));
}

// Finite integer simplexes exercise semantics, not model calibration.
test "exhaustive bool threshold monotonicity on integer probability simplex" {
    for (0..101) |true_weight| {
        const p = @as(f64, @floatFromInt(true_weight)) / 100;
        var previous = true;
        for (0..101) |threshold_weight| {
            const threshold = @as(f64, @floatFromInt(threshold_weight)) / 100;
            const result = try decode(bool, testResponse(&.{testPredicate(p)}), .{ .instructions = "Yes?", .threshold = threshold });
            try testing.expectEqual(true_weight >= threshold_weight, result.value);
            try testing.expect(previous or !result.value);
            try testing.expect(unitInterval(result.details.probability));
            previous = result.value;
        }
    }
}

fn exerciseChoicePermutation(weights: [3]u32, order: [3]usize) !void {
    const names = @typeInfo(TestChoice).@"enum".field_names;
    const total = weights[0] + weights[1] + weights[2];
    var distribution: [3]api.ChoiceProbabilityResource = undefined;
    var max_index: usize = 0;
    for (weights, 0..) |weight, i| if (weight > weights[max_index]) {
        max_index = i;
    };
    for (order, &distribution) |index, *entry| entry.* = .{
        .value = .{ .string = names[index] },
        .probability = @as(f64, @floatFromInt(weights[index])) / @as(f64, @floatFromInt(total)),
    };
    var answer = testChoice();
    answer.choice.probabilities = &distribution;
    answer.choice.choice = .{ .string = names[max_index] };
    const result = try decode(TestChoice, testResponse(&.{answer}), .{ .instructions = "Choose" });
    try testing.expectEqualStrings(names[max_index], @tagName(result.value));
    for (std.enums.values(TestChoice), weights) |key, weight| {
        const p = result.details.probabilities.get(key);
        try testing.expect(unitInterval(p));
        try testing.expectEqual(@as(f64, @floatFromInt(weight)) / @as(f64, @floatFromInt(total)), p);
    }
}

test "exhaustive enum integer simplexes and all distribution permutations" {
    const permutations = [_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } };
    for (0..11) |a| for (0..11 - a) |b| {
        const weights: [3]u32 = .{ @intCast(a), @intCast(b), @intCast(10 - a - b) };
        for (permutations) |permutation| try exerciseChoicePermutation(weights, permutation);
    };
}

test "seeded finite probability distributions and permutations" {
    var prng = std.Random.DefaultPrng.init(0xa892f041);
    const random = prng.random();
    for (0..1000) |_| {
        const a = random.uintLessThan(u32, 10001);
        const b = random.uintLessThan(u32, 10001 - a);
        var order = [_]usize{ 0, 1, 2 };
        random.shuffle(usize, &order);
        try exerciseChoicePermutation(.{ a, b, 10000 - a - b }, order);
        const p = @as(f64, @floatFromInt(a)) / 10000;
        const low = random.float(f64);
        const high = low + (1 - low) * random.float(f64);
        const lower = try decode(bool, testResponse(&.{testPredicate(p)}), .{ .instructions = "Yes?", .threshold = low });
        const upper = try decode(bool, testResponse(&.{testPredicate(p)}), .{ .instructions = "Yes?", .threshold = high });
        try testing.expect(lower.value or !upper.value);
    }
}

fn testBuildAllocationFailures(backing: Allocator) !void {
    // Disable resizing so the arena cannot hide an injected failed allocation
    // by successfully growing its previous allocation instead.
    var no_resize = testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(no_resize.allocator());
    defer arena.deinit();
    const Output = struct { accepted: bool, category: TestChoice, grade: f64, alternate: TestChoice };
    const built = try buildQuestions(Output, arena.allocator(), .{
        .accepted = .{ .instructions = "Accept?" },
        .category = .{ .instructions = "Choose", .descriptions = &.{.{ .value = .@"send.review", .description = "Review" }} },
        .grade = test_score_question,
        .alternate = .{ .instructions = "Alternative" },
    });
    try testing.expectEqual(@as(usize, 4), built.len);
    try testing.expectEqualStrings("medium", built[2].score.levels[1].label);
}

test "build OOM cleans caller arena with nested failing allocator and no resizing" {
    try testing.checkAllAllocationFailures(testing.allocator, testBuildAllocationFailures, .{});
}

fn testFieldNames(comptime n: usize) [n][:0]const u8 {
    @setEvalBranchQuota(200_000);
    var names: [n][:0]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("question_{d}", .{i});
    return names;
}

test "maximum 400 question names stay unique and ordered without output defaults" {
    const names = comptime testFieldNames(400);
    const Output = @Struct(.auto, null, &names, &@as([400]type, @splat(bool)), &@splat(.{}));
    var questions: QuestionFields(Output) = undefined;
    var answers: [400]api.AnswerResource = undefined;
    inline for (names, &answers, 0..) |name, *answer, i| {
        @field(questions, name) = .{ .instructions = "Yes?" };
        answer.* = .{ .predicate = .{ .name = name, .type = "predicate", .probability = if (i % 2 == 0) 1 else 0 } };
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try buildQuestions(Output, arena.allocator(), questions);
    try testing.expectEqual(@as(usize, 400), built.len);
    for (names, built) |name, q| try testing.expectEqualStrings(name, q.predicate.name.?);
    const result = try decode(Output, testResponse(&answers), questions);
    inline for (names, 0..) |name, i| try testing.expectEqual(i % 2 == 0, @field(result.value, name));
}

test "maximum 255 enum choices preserve names without assuming dense tags" {
    const names = comptime testFieldNames(255);
    const values = comptime blk: {
        var result: [255]u16 = undefined;
        for (&result, 0..) |*value, i| value.* = @intCast(i * 5 + 3);
        break :blk result;
    };
    const E = @Enum(u16, .exhaustive, &names, &values);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try buildQuestions(E, arena.allocator(), .{ .instructions = "Choose" });
    try testing.expectEqual(@as(usize, 255), built[0].choice.choices.len);
    var probabilities: [255]api.ChoiceProbabilityResource = undefined;
    for (&probabilities, names, 0..) |*p, name, i| p.* = .{ .value = .{ .string = name }, .probability = if (i == 254) 1 else 0 };
    const answer: api.AnswerResource = .{ .choice = .{
        .name = "decision",
        .type = "choice",
        .choice = .{ .string = names[254] },
        .confidence = 0,
        .probabilities = &probabilities,
    } };
    const result = try decode(E, testResponse(&.{answer}), .{ .instructions = "Choose" });
    try testing.expectEqualStrings(names[254], @tagName(result.value));
    try testing.expectEqual(@as(f64, 1), result.details.probabilities.get(@field(E, names[254])));
    try testing.expectEqual(@as(f64, 0), result.details.confidence);
}

test "minimum two and maximum ten ordered score levels are accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var levels: [10]ScoreLevel = undefined;
    var probabilities: [10]api.ScoreProbabilityResource = undefined;
    const labels = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    for (labels, &levels, &probabilities, 0..) |label, *level, *p, i| {
        level.* = .{ .label = label };
        p.* = .{ .value = @intCast(i), .label = label, .probability = 0 };
    }
    for ([_]usize{ 2, 10 }) |n| {
        probabilities[0].probability = 0.25;
        probabilities[n - 1].probability = 0.75;
        const questions: FloatQuestion = .{ .score = .{ .instructions = "Score", .levels = levels[0..n], .scale = .{ .minimum = -100, .maximum = 100 } } };
        const built = try buildQuestions(f32, arena.allocator(), questions);
        try testing.expectEqual(n, built[0].score.levels.len);
        const answer: api.AnswerResource = .{ .score = .{
            .name = "decision",
            .type = "score",
            .score = @as(f64, @floatFromInt(n - 1)) * 0.75,
            .confidence = 1,
            .probabilities = probabilities[0..n],
        } };
        const result = try decode(f32, testResponse(&.{answer}), questions);
        try testing.expectEqual(@as(f32, 50), result.value);
        probabilities[n - 1].probability = 0;
    }
}

fn testOwnerAllocationFailures(backing: Allocator) !void {
    const arena = try backing.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(backing);
    errdefer destroyArena(arena);
    const raw = try arena.allocator().dupe(u8, "owned response");
    const model = try arena.allocator().dupe(u8, "gpt-6-luna");
    var response: Response = .{ .arena = arena, .value = testResponse(&.{}), .raw_response = raw, .usage = .{}, .model = model };
    response.deinit();
}

test "owner wrappers preserve public params and stable arena lifetime" {
    const create: CreateParams = .{ .input = "text", .questions = &.{} };
    const parse: ParseParams(bool) = .{ .input = "text", .questions = .{ .instructions = "Yes?" } };
    try testing.expect(create.model == null and parse.model == null);
    try testing.expectEqual(@as(usize, 0), create.extra_headers.len + parse.extra_query.len);
    try testing.checkAllAllocationFailures(testing.allocator, testOwnerAllocationFailures, .{});
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed_value = try decode(bool, testResponse(&.{testPredicate(0.8)}), parse.questions);
    var parsed: Parsed(bool) = .{
        .arena = arena,
        .value = parsed_value.value,
        .details = parsed_value.details,
        .response = testResponse(&.{}),
        .raw_response = "",
        .usage = .{},
        .model = "gpt-6-luna",
    };
    try testing.expect(parsed.value);
    parsed.deinit();
}
