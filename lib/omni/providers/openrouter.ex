defmodule Omni.Providers.OpenRouter do
  @moduledoc false

  # Provider for the OpenRouter API, using the `Omni.Dialects.OpenAICompletions`
  # dialect for text and `Omni.Dialects.TypeSafeSystemOne` for decisions.
  #
  # Decisions:
  #
  # Decision models (`typesafe/jev-1.14`, `liquid/d1` and others) are sent to
  # `/api/v1/systemone`, OpenRouter's System One route. OpenRouter also
  # serves the same wire format at `/api/alpha/decisions`, which it marks as
  # subject to change.
  #
  # Reasoning:
  #
  # `:thinking` is supported and sent as `reasoning.effort`. Reasoning is sent
  # back on later turns of a conversation, as OpenRouter's `reasoning_details`,
  # with no extra handling needed.
  #
  # Caching:
  #
  # Claude models (`anthropic/*`) cache only when asked. With `:cache` set,
  # they are sent a top-level `cache_control` (`ttl: "1h"` for `:long`), and
  # OpenRouter places the breakpoint on the last cacheable block. This is done
  # in the module's `modify_body/4`, for models on the
  # Completions dialect.
  #
  # Other upstreams cache automatically, whatever `:cache` says (Gemini and
  # Qwen were verified). OpenRouter documents per-block `cache_control`
  # markers for some Qwen models, which Omni doesn't send.
  #
  # What users are told is the "OpenRouter" section of
  # guides/built-in-providers.md; keep it in step with this module.

  @behaviour Omni.Provider

  @impl true
  def config do
    [
      api_key: {:system, "OPENROUTER_API_KEY"},
      dialects: %{
        Omni.Dialects.OpenAICompletions => [
          base_url: "https://openrouter.ai/api/v1",
          compat: [
            thinking_effort_field: "reasoning.effort",
            thinking_replay_format: :reasoning_details
          ]
        ],
        # Decision models, at /api/v1/systemone. Set here because llm_db
        # describes them at OpenRouter's origin, for its alpha route.
        Omni.Dialects.TypeSafeSystemOne => [base_url: "https://openrouter.ai/api/v1"]
      }
    ]
  end

  # Claude caches only on request. OpenRouter takes Anthropic's
  # `cache_control` at the top level of a Completions body and places the
  # breakpoint itself, on the last cacheable block. `prompt_cache_retention`
  # is OpenAI's field, so it goes. Completions only: a model moved to
  # another dialect is that dialect's to cache.
  @impl true
  def modify_body(
        body,
        %Omni.Model{id: "anthropic/" <> _, dialects: %{text: Omni.Dialects.OpenAICompletions}},
        %Omni.Context{},
        %{cache: cache}
      )
      when cache in [:short, :long] do
    body
    |> Map.delete("prompt_cache_retention")
    |> Map.put("cache_control", cache_control(cache))
  end

  def modify_body(body, _model, _input, _opts), do: body

  defp cache_control(:short), do: %{"type" => "ephemeral"}
  defp cache_control(:long), do: %{"type" => "ephemeral", "ttl" => "1h"}
end
