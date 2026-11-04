# Typed decisions

Use `client.decisions.parse(T, params)` to ask small questions about text and use the answers in ordinary Zig control flow. Instructor sends the questions to OpenAI's `POST /v1/decisions` endpoint. It does not ask a chat model to write JSON that matches an output schema.

Ask the model for individual judgments. Keep hard rules and actions in your program. For example, ask whether a passage answers a search query, then use `if` to include it in the results. Check uncertainty before taking that branch.

## Run the examples

The [offline example](../examples/decisions_offline.zig) uses an injected transport with a fixed response. It needs no API keys and opens no network connection.

```sh
zig build run-decisions-offline
```

It asks two questions in one request. The program uses an enum for the support team and a boolean for urgency. The example prints the probabilities and verifies that the transport received one request.

The following commands make live requests and may incur charges. Set `OPENAI_API_KEY` before running them. Your account must have access to the selected model.

```sh
zig build run-decisions
zig build run-smart-if
```

The [ticket example](../examples/decisions.zig) includes an exhaustive `switch` and a predicate probability. The [smart if example](../examples/smart_if.zig) checks an uncertain range before branching on a root boolean.

Both live examples use this client configuration:

```zig
var client = try instructor.Client.fromEnv(init, .{
    .provider = .openai,
    .model = "gpt-6-luna",
});
defer client.deinit();
```

## Define the answers and questions

`T` can be `bool`, an exhaustive enum, `f32`, or `f64`. It can also be a flat struct whose fields have those types. `instructor.decisions.Questions(T)` has the same field names as the struct. Supply a question for every field.

```zig
const Team = enum { billing, technical, other };
const TicketDecision = struct { team: Team, urgent: bool };

const questions: instructor.decisions.Questions(TicketDecision) = .{
    .team = .{
        .instructions = "Which team should review this support ticket?",
        .descriptions = &.{
            .{ .value = .billing, .description = "Charges, invoices, or refunds." },
            .{ .value = .technical, .description = "Problems using the product." },
            .{ .value = .other, .description = "Requests outside these categories." },
        },
    },
    .urgent = .{
        .instructions = "Does the ticket need attention today?",
        .threshold = 0.8,
    },
};

const ticket = "I was charged twice. Please fix this today.";
var decision = try client.decisions.parse(TicketDecision, .{
    .input = ticket,
    .questions = questions,
});
defer decision.deinit();
```

Keep the question instructions separate from the input you are evaluating. All fields share that input and go in one HTTP request. Use separate calls if a later question depends on an earlier answer.

For a scalar `T`, supply `instructor.decisions.Question(T)` directly in `questions`. Instructor names that single question `decision` in the request. For a struct, the question names are the field names.

| Output type | Question | Value and details |
| --- | --- | --- |
| `bool` | Set `instructions` and an optional `threshold`, which defaults to `0.5`. | `value` is true when the probability is greater than or equal to the threshold. `details.probability` is the original probability. |
| Exhaustive enum | Set `instructions` and optional `descriptions` entries with `value` and `description`. | `value` is the selected enum case. `details.probabilities` is a `std.EnumArray(E, f64)`. `details.confidence` is the provider's confidence. |
| `f32` or `f64` | Choose `.predicate` with `instructions`. | `value` is the probability. `details` is a union with `.predicate.probability`. |
| `f32` or `f64` | Choose `.score` with `instructions`, ordered `levels`, and an optional `scale`. | `value` is the weighted level index, or its scaled value. `details` is a union with `.score` details. |

For struct outputs, use the same field names in `details`, e.g., `decision.details.team.probabilities.get(.billing)` or `decision.details.urgent.probability`.

## Check uncertainty before branching

A root boolean needs no wrapper struct:

```zig
const question = "Does the passage directly help answer the search query?";
const input = "Query: Reset my password. Passage: Use 'Forgot password' to get a reset link.";
var decision = try client.decisions.parse(bool, .{
    .input = input,
    .questions = .{
        .instructions = question,
        .threshold = 0.8,
    },
});
defer decision.deinit();

const probability = decision.details.probability;
if (probability > 0.2 and probability < 0.8) {
    std.debug.print("Send for manual review.\n", .{});
    return;
}
if (decision.value) {
    std.debug.print("Include the passage.\n", .{});
} else {
    std.debug.print("Leave the passage out.\n", .{});
}
```

These thresholds are illustrative. Choose thresholds and review ranges using labeled examples from your application. Consider the cost of accepting a wrong answer and rejecting a useful one.

A probability is a model estimate, not a guarantee that the answer is correct. For choice and score answers, `confidence` is a separate value reported by the provider. Do not treat it as the probability that the answer is correct. Instructor does not retry an answer because its probability or confidence is low.

## Use a probability or rubric score

For a probability without a boolean threshold, use a float with a predicate question:

```zig
const question: instructor.decisions.Question(f64) = .{ .predicate = .{
    .instructions = "Is the customer unable to continue their work?",
} };
```

For an ordered rubric, use a score question:

```zig
const question: instructor.decisions.Question(f64) = .{ .score = .{
    .instructions = "How much does this issue interfere with the customer's work?",
    .levels = &.{
        .{ .label = "Cosmetic", .description = "Appearance only." },
        .{ .label = "Workaround available", .description = "Another way to finish the task exists." },
        .{ .label = "Blocked", .description = "The task cannot be completed." },
    },
    .scale = .{ .minimum = 0, .maximum = 100 },
} };
```

Pass either question as `.questions = question` to `client.decisions.parse(f64, params)`. In a struct, assign it to the corresponding float field in `questions`.

Each score level has a `label` and an optional `description`. Levels start at index zero. The provider's raw score is the sum of each index multiplied by its probability. A score can fall between levels. Use an enum when you need one category instead.

Without `scale`, the output is the weighted index. With `scale`, Instructor maps index zero to `minimum` and the last index to `maximum` with a linear transformation. For three levels, a raw score of `1.1` maps to `55` on a scale from `0` to `100`.

Use `switch` on float `details` to distinguish `.predicate` from `.score`. Score details include the provider's raw `score`, its native SDK `probabilities` array, and its reported `confidence`. The optional scale changes the typed value, not these details or the native response.

## Use native SDK questions

Use `client.decisions.create(params)` when you want to supply OpenAI SDK question types directly and inspect native answers yourself:

```zig
const question = "Does the passage answer the query?";
const input = "Query: Reset my password. Passage: Use 'Forgot password'.";
var result = try client.decisions.create(.{
    .input = input,
    .questions = &.{.{ .predicate = .{
        .name = "relevant",
        .type = "predicate",
        .instructions = .{ .string = question },
    } }},
});
defer result.deinit();

// result.value is the native OpenAI DecisionResponse.
// Inspect result.value.answers and handle refusals and answer variants.
```

This method does not convert answers into a Zig output type or apply boolean thresholds. Both methods accept an optional request `model` override. They also accept `extra_body`, `extra_headers`, and `extra_query`. See [request extras](client.md#request-extras) for the merge rules. Both methods accept only text input. OpenAI also supports other input forms.

## Own the result

The result of `parse` is an owned `instructor.decisions.Parsed(T)`.

* `value` is the typed result.
* `details` contains the probabilities and provider confidence for each answer.
* `response` is the complete native OpenAI `DecisionResponse`.
* `raw_response` contains the exact response JSON bytes.
* `status` is the HTTP response status.
* `usage` contains the common token counts.
* `model` is the returned model name.

Use `response.usage` for native usage details such as cached input tokens. The result of `create` has the native response in `value` instead of separate typed `value`, `details`, and `response` fields.

Call `deinit()` once on each result. Do not copy an active owner. Result data remains valid after client cleanup if its backing allocator is still alive. Data borrowed from a result must not outlive that result. Keep the client alive while using its `decisions` resource, and do not run calls concurrently on one client.

## Limits and failures

The typed API does not support freeform string or integer outputs. Nested structs, arrays, optionals, and output unions are also unsupported. A flat output struct must have between 1 and 400 fields. Enums need between 2 and 255 cases, and score questions need between 2 and 10 levels.

Invalid questions or answers fail rather than supplying default values or partial results. Typed parsing checks the answer names and types. It also checks probability distributions. A provider refusal is an error. Use normal Zig error handling and send failed cases for review when needed. These checks do not establish that a model's judgment is correct.

This resource requires the OpenAI provider. It uses the Decisions endpoint rather than the configured Responses or Chat Completions endpoint. It does not provide an Anthropic Decisions adapter or a TypeSafe adapter.

## Jev and other decision APIs

The useful principle in [TypeSafe's introduction to Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) is to ask the model for small judgments and keep the workflow in code. Apply hard rules in your program. Decide in code when to branch or request manual review. Restricting the answer type does not guarantee a correct judgment.

TypeSafe's Jev uses `POST /v1/systemone` with `state` and a map of named questions. OpenAI uses `POST /v1/decisions` with `input` and an array of questions, including the `predicate` type. OpenRouter's `/api/alpha/decisions` uses the TypeSafe format, not the OpenAI format. Changing `base_url` alone is not enough to use Jev with this resource.

For the provider contract, see the [OpenAI Decisions guide](https://developers.openai.com/api/docs/guides/decisions). The [Instructor Python decisions guide](https://python.useinstructor.com/concepts/decisions/) and [Pydantic AI decision model guide](https://pydantic.dev/docs/ai/models/decision/) describe related ways to use typed decisions. Their client APIs are not the Zig API documented here.
