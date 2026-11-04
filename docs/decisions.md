# Decisions

Use OpenAI's Decisions API for questions with a fixed set of answers.

## A boolean condition

`condition` returns a boolean and cleans up the response internally.

```zig
if (try client.decisions.condition(.{
    .input = passage,
    .instructions = "Does this passage answer the search query?",
    .threshold = 0.8,
})) {
    includePassage();
} else {
    omitPassage();
}
```

The result is true when the probability is at least the threshold. The default threshold is `0.5`. Errors are returned, not converted to false.

Each call makes a live model request. Choose thresholds using labeled examples from your application.

## Reuse a set of questions

Define the answer type and questions once.

```zig
const Team = enum { billing, technical, other };
const TicketDecision = struct {
    team: Team,
    urgent: bool,
};

const questions = instructor.decisions.Questions(TicketDecision).init(&client, .{
    .team = .{ .instructions = "Which team should handle this ticket?" },
    .urgent = .{
        .instructions = "Does this need attention today?",
        .threshold = 0.8,
    },
});

const decision = try questions.parse(.{ .input = ticket });

switch (decision.team) {
    .billing => queueBilling(),
    .technical => queueTechnical(),
    .other => queueForReview(),
}
```

`parse` returns `TicketDecision` and frees the response internally. There is no result to deinitialize. Each call sends all questions in one request. Keep question instructions separate from the text being judged.

The question set borrows the client and instruction strings. Keep them alive while using it. Initialization makes no request and allocates no memory.

## Keep probabilities when needed

Use `parseDetailed` when your code needs response details.

```zig
var decision = try questions.parseDetailed(.{ .input = ticket });
defer decision.deinit();

const probability = decision.details.urgent.probability;
const billing = decision.details.team.probabilities.get(.billing);
```

Use these probabilities to handle uncertain answers separately. A model estimate is not a guarantee of correctness. Provider confidence is a separate value, not the probability that an answer is correct. Low confidence does not trigger a retry.

A detailed result also contains the native `response`, exact `raw_response`, HTTP `status`, `usage`, and returned `model`. Its data can outlive the client if the backing allocator stays alive.

## Supported types

| Zig type | Answer |
| --- | --- |
| `bool` | A predicate probability compared with a threshold. |
| Exhaustive enum | One of its cases. Optional descriptions explain each case. |
| `f32` or `f64` | A predicate probability or an ordered rubric score. |
| Flat struct | One question per field, using the types above. |

For floats, choose `.predicate` or `.score` explicitly:

```zig
const score: instructor.decisions.Question(f64) = .{ .score = .{
    .instructions = "How much does this issue affect the customer's work?",
    .levels = &.{
        .{ .label = "Cosmetic" },
        .{ .label = "Workaround available" },
        .{ .label = "Blocked" },
    },
    .scale = .{ .minimum = 0, .maximum = 10 },
} };
```

A score is a weighted level index and may fall between levels. The optional scale maps the first and last levels to your bounds.

Enums support 2 to 255 cases. Scores support 2 to 10 levels. Structs support 1 to 400 fields. Strings, integers, nested structs, and optional outputs are not supported.

## Requests and cleanup

`questions.parse` and `parseDetailed` accept a model override and [request extras](client.md#request-extras). Input and request options are borrowed until the call returns.

For inline questions, `client.decisions.parse(T, params)` returns an owned detailed result. Use `client.decisions.create(params)` for native SDK questions and answers.

Deinitialize the client once. Deinitialize detailed results once. Keep the client alive while using its question sets. Do not run calls concurrently on one client. Malformed answers and refusals return errors.

## Run the examples

Set `OPENAI_API_KEY`. Both examples use `gpt-6-luna` and make live requests.

```sh
zig build run-smart-if
zig build run-decisions
```

See [the boolean example](../examples/smart_if.zig) and [ticket routing](../examples/decisions.zig).

This resource calls OpenAI's `/v1/decisions` endpoint with text input. Jev uses a different request format, so changing the base URL alone will not work.

See [OpenAI's API guide](https://developers.openai.com/api/docs/guides/decisions) and [TypeSafe's Jev introduction](https://typesafe.ai/blog/introducing-system-one-models-and-jev).
