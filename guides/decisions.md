# Decisions

A decision model answers questions about an input with probabilities instead of prose. Ask whether a support ticket is urgent and you get `0.91`, not a paragraph. That makes decision models a good fit for routing, classifying, moderating and scoring: jobs where code reads the answer and a number is more use than a sentence.

`Omni.decide/3` is the whole API. It takes a model, a state and a list of typed questions, and returns an answer for each in one request. Nothing is streamed.

## A first decision

```elixir
ticket = "I've been charged twice for my order and nobody is answering the phone!"

{:ok, decision} =
  Omni.decide("openrouter:typesafe/jev-1.14", {ticket, [
    urgent: Omni.predicate("Does this need a reply within the hour?"),
    team: Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil),
    anger: Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
  ]})

decision.answers[:urgent]
#=> %Omni.Answer.Predicate{probability: 0.91}

decision.answers[:team]
#=> %Omni.Answer.Choice{choice: :billing, probabilities: [billing: 0.95, infra: 0.02, other: 0.03], confidence: 0.93}

decision.answers[:anger]
#=> %Omni.Answer.Score{score: 1.4, probabilities: [{"Calm", 0.1}, {"Frustrated but civil", 0.4}, {"Very angry", 0.5}], confidence: 0.4}
```

The second argument is `{state, questions}`. The state is the input every question is asked about. The questions are a keyword list: each key names a question, and the same key finds its answer.

## Questions

There are three types, and the type decides the shape of the answer.

### Predicate

A yes or no question, answered with the probability that the answer is yes. The optional criteria describe what counts as true and false.

```elixir
Omni.predicate("Is this spam?")
Omni.predicate("Is this spam?", true: "Unsolicited advertising", false: "A real conversation")
```

### Choice

Picks one of a set of options, answered with the most likely option and a probability for each.

Give the options as keys, or as `key: description` pairs where a description helps the model judge. Keys can be atoms or strings, and the answer uses them as you wrote them.

```elixir
Omni.choice("What is the tone?", [:calm, :frustrated, :angry])
Omni.choice("Which team owns this?", billing: "Payments and refunds", infra: "Outages", other: nil)
```

### Score

Rates the state on an ordered scale, from the lowest level to the highest.

The answer has a probability for each level, and a `score`: their weighted average, counting the first level as 0. A score of `1.4` on a three-level scale sits between the second and third levels.

```elixir
Omni.score("How angry is the customer?", ["Calm", "Frustrated but civil", "Very angry"])
Omni.score("How severe is the bug?", low: "Cosmetic", medium: "Has a workaround", high: "Blocks the user")
```

## Reading answers

`decision.answers` is a keyword list in the order of the questions. Match on the struct:

```elixir
case decision.answers[:team] do
  %Omni.Answer.Choice{choice: team, confidence: c} when c > 0.8 -> route(team)
  %Omni.Answer.Choice{} -> route(:triage)
  %Omni.Answer.Refusal{} -> route(:manual)
end
```

Probabilities come back as the model gave them, unrounded, as `{key, probability}` pairs in the order of the question. Because you get the whole distribution, you choose the threshold: act on a predicate at `0.5`, or only above `0.95` when a wrong yes is costly.

`confidence` is the provider's own measure of how sure the answer is, or `nil` when it gives none. Providers work it out differently, so compare it only between answers from the same provider. The probabilities are the result you can rely on anywhere.

A model may decline a question, which gives an `Omni.Answer.Refusal` for that question. The other questions are still answered.

The decision also carries `usage`, with token counts and cost, and the `model` that answered.

## State and instructions

The state can be more than a string. Give a map and it is sent as JSON; give a list and each item is a part, in order:

```elixir
Omni.decide(model, {
  %{subject: "Refund", plan: "enterprise", body: body},
  questions
})

Omni.decide(model, {
  ["Ticket from an enterprise customer:", %{subject: "Refund", body: body}],
  questions
})
```

To send an array as data, put it inside a map (`%{readings: [3, 5, 8]}`), since a list on its own means several parts.

A question's instructions take the same forms, so a question can carry data of its own:

```elixir
Omni.predicate([
  "Does the ticket mention any of these products?",
  %{products: product_names}
])
```

## Models and providers

Decision models are listed with a provider's other models. `Omni.Model.capability?/2` tells them apart:

```elixir
{:ok, models} = Omni.list_models(:openrouter)

models
|> Enum.filter(&Omni.Model.capability?(&1, :decision))
|> Enum.map(& &1.id)
```

These built-in providers serve decision models:

| Provider | Models |
| --- | --- |
| TypeSafe (`:typesafe`) | The Jev family: `jev-latest`, `jev-1.14.0` |
| OpenAI (`:openai`) | `gpt-6-luna`, which serves text too |
| OpenRouter (`:openrouter`) | Decision models from several labs |
| OpenCode Zen (`:opencode`) | `jev-1.13` |
| NEAR AI Cloud (`:nearai`) | `typesafe/jev-1.13` |
| Ollama (`:ollama`) | Any decision model you have pulled |

Two wire formats, or [dialects](providers-and-models.md#three-ideas), are in use: TypeSafe's System One, which most providers serve, and OpenAI's Decisions API. Omni speaks both, and your code is the same either way. One difference shows through: OpenAI has no field for a predicate's criteria, so they are not sent to it.

A local Ollama model is a decision model when its config says so:

```elixir
config :omni, :providers,
  ollama: [models: [
    [id: "clef", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}]
  ]]
```

Calling `Omni.decide/3` on a text model, or `Omni.generate_text/3` on a decision model, returns `{:error, {:unsupported_capability, capability}}` with no request made.

## Options and errors

`Omni.decide/3` takes `:api_key`, `:host`, `:headers`, `:timeout` and `:raw`, as text requests do.

Questions are checked before anything is sent: a decision needs at least one question, every question needs instructions, and a choice or score needs two or more options. Providers set their own limits on how many questions and options a request may hold, and report them as HTTP errors.

If a provider's response is missing an answer, or has one of the wrong type, the result is `{:error, {:invalid_answer, name}}`.

## Keeping decisions

A decision is one struct holding the request and the result, so it is easy to log or store. `Omni.Codec.encode/1` turns it into a JSON-safe map and `Omni.Codec.decode/2` brings it back, questions, answers and usage included.
