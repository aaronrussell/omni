defmodule Omni.Providers.OpenRouter do
  @moduledoc false

  # The built-in `:openrouter` provider: the OpenRouter API, over Chat
  # Completions for text and System One for decisions.
  #
  # - Decisions go to `/api/v1/systemone`. OpenRouter serves the same wire
  #   format at `/api/alpha/decisions`, which it marks as subject to change.
  # - Claude models cache only when asked, which `modify_body/4` does. Other
  #   upstreams cache automatically, whatever `:cache` says (Gemini and Qwen
  #   were verified). OpenRouter documents per-block `cache_control` markers for
  #   some Qwen models, which Omni doesn't send.
  #
  # Users read about it in the "OpenRouter" section of
  # guides/built-in-providers.md. Keep that in step with this module.

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
