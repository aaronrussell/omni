# Built-in providers

Omni ships with code for the providers on this page. Each is set up for its API's quirks, loads by default, and is run against the live API before a release where we have an account to do it. They are not the only providers Omni works with: any provider in the models.dev catalog loads by its id, and you can define your own (see [Providers and models](providers-and-models.md)). These are the ones where the work has been done for you.

| Provider | Id | API key variable | Text API | Decision API |
| --- | --- | --- | --- | --- |
| [Alibaba](#alibaba) | `:alibaba` | `DASHSCOPE_API_KEY` | `"openai_completions"` | |
| [Anthropic](#anthropic) | `:anthropic` | `ANTHROPIC_API_KEY` | `"anthropic_messages"` | |
| [Google](#google) | `:google` | `GEMINI_API_KEY` | `"google_generate_content"` | |
| [Groq](#groq) | `:groq` | `GROQ_API_KEY` | `"openai_completions"` | |
| [Mistral AI](#mistral-ai) | `:mistral` | `MISTRAL_API_KEY` | `"openai_completions"` | |
| [Moonshot AI](#moonshot-ai) | `:moonshotai` | `MOONSHOT_API_KEY` | `"openai_completions"` | |
| [NEAR AI Cloud](#near-ai-cloud) | `:nearai` | `NEARAI_API_KEY` | `"openai_completions"` | `"typesafe_system_one"` |
| [Ollama](#ollama) | `:ollama` | none | `"ollama_chat"` | `"typesafe_system_one"` |
| [Ollama Cloud](#ollama-cloud) | `:ollama_cloud` | `OLLAMA_API_KEY` | `"ollama_chat"` | |
| [OpenAI](#openai) | `:openai` | `OPENAI_API_KEY` | `"openai_responses"` | `"openai_decisions"` |
| [OpenCode Zen](#opencode-zen) | `:opencode` | `OPENCODE_API_KEY` | *by model* | `"typesafe_system_one"` |
| [OpenRouter](#openrouter) | `:openrouter` | `OPENROUTER_API_KEY` | `"openai_completions"` | `"typesafe_system_one"` |
| [Together AI](#together-ai) | `:togetherai` | `TOGETHER_API_KEY` | `"openai_completions"` | |
| [TypeSafe](#typesafe) | `:typesafe` | `TYPESAFE_API_KEY` | | `"typesafe_system_one"` |
| [Venice AI](#venice-ai) | `:venice` | `VENICE_API_KEY` | `"openai_completions"` | |
| [xAI](#xai) | `:xai` | `XAI_API_KEY` | `"openai_responses"` | |
| [Z.ai](#z-ai) | `:zai` | `ZAI_API_KEY` | `"openai_completions"` | |

If a provider's variable is set, it needs no configuration. To change anything about one, configure it by id:

```elixir
config :omni, :providers, anthropic: [api_key: {:system, "MY_ANTHROPIC_KEY"}]
```

To see exactly how a provider is set up, including its URLs and compat flags, look at the loaded struct:

```elixir
{:ok, provider} = Omni.get_provider(:zai)
provider.dialects
```

## Alibaba

Alibaba Cloud's DashScope API, serving the Qwen models.

**Regions.** The default is the International (Singapore) endpoint. Every region serves the same paths, so choose another with `:host`:

```elixir
config :omni, :providers, alibaba: [host: "https://dashscope-us.aliyuncs.com"]
```

| Region | Host |
| --- | --- |
| International (Singapore) | `https://dashscope-intl.aliyuncs.com` |
| US (Virginia) | `https://dashscope-us.aliyuncs.com` |
| Germany (Frankfurt) | `https://{WorkspaceId}.eu-central-1.maas.aliyuncs.com` |
| China (Beijing) | `https://dashscope.aliyuncs.com` |
| China (Hong Kong) | `https://cn-hongkong.dashscope.aliyuncs.com` |

The catalog also lists the Beijing endpoint as a provider of its own, `:alibaba_cn`. Give it Alibaba's setup with `compat: [like: :alibaba]` (see [Compat flags](providers-and-models.md#compat-flags)).

**Thinking.** Most models switch thinking on and off and take a token budget, which Omni sizes from the effort level. Models that take effort levels are given the nearest one.

**Structured output.** Alibaba has no schema-constrained output, so Omni uses JSON mode and describes the schema in the system prompt. The answer is still validated and retried.

## Anthropic

The Claude models, over Anthropic's Messages API. Nothing particular to note. Prompt caching happens only when you pass `:cache`.

## Google

The Gemini models, over the Gemini API's `generateContent`. Nothing particular to note.

## Groq

**Thinking.** The effort levels a model accepts vary by model family, and each level is rounded to the nearest the model has, so `:xhigh` and `:max` may become the model's highest.

Reasoning always arrives apart from the answer. Groq's default for some models, such as Qwen, is to put reasoning inside the answer as `<think>` tags, so Omni asks those models for it separately. This lives in Groq's provider module rather than a compat flag, so `like: :groq` doesn't copy it.

## Mistral AI

**Thinking.** Mistral's own reasoning models have a single effort level, so every `:thinking` level asks for `"high"` and `thinking: false` asks for `"none"`. Other models Mistral serves, such as GLM, take their own levels.

**Limitations.**

- PDF attachments are not supported.
- Tool use ids must be nine letters and digits. Mistral's own are, but a conversation holding tool uses from another provider is rejected.

## Moonshot AI

The Kimi models. The catalog lists the China endpoint as a provider of its own, `:moonshotai_cn`. Give it Moonshot's setup with `compat: [like: :moonshotai]`.

**Thinking.** Models that take effort levels are given the nearest one. The rest switch thinking on and off.

**Limitations.** Kimi K2.6 ignores the `:output` schema while it is thinking, which it does by default, and answers in prose. Pass `thinking: false` with `:output`. Kimi K2.7 and K3 follow the schema with thinking on.

## NEAR AI Cloud

Models served from trusted execution environments.

**Limitations.** The `:thinking` and `:cache` options are not sent, and structured output schemas are not marked strict.

**Decisions.** The catalog's decision models (`typesafe/jev-1.13`, `levanto/sage-1.4`) load over System One. NEAR AI doesn't document this endpoint, and it hasn't been checked against the live API.

## Ollama

An Ollama running on your machine, at `http://localhost:11434`, with no authentication.

**Models.** A local Ollama's models are whatever you have pulled, so there is no catalog to load them from, and without config the provider has none. List them, each as an id or as a keyword list of `Omni.Model.new/1` attributes:

```elixir
config :omni, :providers,
  ollama: [
    models: [
      "mistral:7b",
      [id: "llama3.1:8b", name: "Llama 3.1 8B", context_size: 128_000, max_output_tokens: 8192],
      [id: "qwen3.5:4b", context_size: 32_768, thinking: true]
    ]
  ]
```

A model listed this way is a text model. A decision model names its dialect:

```elixir
config :omni, :providers,
  ollama: [models: [[id: "clef", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}]]]
```

**Another machine.** Set `:host`, which moves text and decision requests together:

```elixir
config :omni, :providers, ollama: [host: "http://192.168.1.10:11434"]
```

**Behind a proxy.** Requests carry no credentials. For an Ollama behind an authenticating proxy, send a key as a Bearer token:

```elixir
config :omni, :providers, ollama: [auth: :bearer, api_key: {:system, "OLLAMA_PROXY_KEY"}]
```

**Limitations.** Images must be base64-encoded. An image given by URL is left out of the request, because Ollama's API has no way to take one.

## Ollama Cloud

Ollama's hosted service, at `https://ollama.com`. The catalog describes its OpenAI-compatible endpoint, but Omni uses Ollama's own chat API, so every text model is moved to it as the provider loads.

**Limitations.**

- Images must be base64-encoded, as with a local Ollama.
- Structured output isn't enforced. Ollama Cloud accepts the `:output` schema but doesn't hold the model to it, so a model may answer in prose and fail validation. A local Ollama does enforce it.

## OpenAI

Text over the Responses API.

**Decisions.** `gpt-6-luna` serves both text and decisions under one model id, the decisions over OpenAI's Decisions API:

```elixir
{:ok, decision} =
  Omni.decide("openai:gpt-6-luna", {"I was charged twice", [
    refund: Omni.predicate("Is the customer asking for a refund?")
  ]})
```

## OpenCode Zen

A gateway to models from several labs. The API depends on the model: Claude models are reached over Anthropic's Messages API, GPT models over Responses, Gemini models over `generateContent`, and the rest over Chat Completions. Each model's dialect comes from the catalog, and each request authenticates the way that API does.

**Decisions.** `jev-1.13` loads over System One.

## OpenRouter

**Decisions.** Decision models (`typesafe/jev-1.14`, `liquid/d1` and others) are reached over OpenRouter's System One route.

**Caching.** Claude models (`anthropic/*`) cache only when you pass `:cache`. Other models cache on their own, whatever `:cache` says.

## Together AI

For inference in the US only, set `host: "https://us-api.together.ai"`.

**Thinking.** Models that take effort levels are given the nearest one. The rest switch thinking on and off. Models that list effort levels and no off switch, such as gpt-oss, can't be switched off, so `thinking: false` does nothing for them.

**Limitations.**

- DeepSeek V4 Pro keeps reasoning with `thinking: false`.
- The `:cache` option is not sent.

## TypeSafe

TypeSafe serves decision models only, over its System One API. Use them with `Omni.decide/3`:

```elixir
{:ok, decision} =
  Omni.decide("typesafe:jev-latest", {"I was charged twice", [
    refund: Omni.predicate("Is the customer asking for a refund?")
  ]})
```

**Models.** models.dev has no TypeSafe entry, so Omni lists the models itself: `jev-1.14.0`, `jev-1.13.0`, and the aliases `jev-latest` and `jev-preview`. A newer release is one config entry away:

```elixir
config :omni, :providers,
  typesafe: [
    models: [[id: "jev-1.15.0", dialects: %{decision: Omni.Dialects.TypeSafeSystemOne}, input_cost: 0.042]]
  ]
```

**Long context.** Requests use TypeSafe's default limit of 64k tokens. Its long-context mode is switched on per request with a header:

```elixir
Omni.decide(model, decision, headers: %{"TypeSafe-Danger-Zone-Long-Context" => "true"})
```

## Venice AI

**Thinking.** Supported, and switched off the way Venice recommends.

**PDFs.** Every Venice model accepts PDF attachments, whatever the model itself takes: Venice extracts the text first.

## xAI

The Grok models, over the Responses API. xAI also serves Chat Completions, as a legacy API. Omni uses Responses because it is the one that returns reasoning in a form that can be sent back on later turns.

**Thinking.** Most Grok models can't switch reasoning off, so `thinking: false` does nothing for them. Models that list a `"none"` effort, such as `grok-4.3`, are switched off. A few models, such as `grok-4.20-0309-reasoning`, reason but reject any effort setting, so `:thinking` is not sent to them at all.

## Z.ai

The GLM models. The catalog lists Z.ai's coding plan, and Zhipu AI's endpoints in China, as providers of their own (`:zai_coding_plan`, `:zhipuai`, `:zhipuai_coding_plan`). Give any of them Z.ai's setup with `compat: [like: :zai]`.

**Thinking.** Models that take effort levels are given the nearest one. The rest switch thinking on and off. By default Z.ai uses earlier reasoning only within a tool loop, and drops reasoning from before the latest user message.

**Structured output.** Z.ai has no schema-constrained output, so Omni uses JSON mode and describes the schema in the system prompt. The answer is still validated and retried.
