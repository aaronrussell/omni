defmodule Omni.Providers.OpenRouter do
  @moduledoc """
  Provider for the OpenRouter API, using the `Omni.Dialects.OpenAICompletions`
  dialect.

  Not loaded by default — must be explicitly enabled. Either add it to your
  provider list in application config:

      config :omni, :providers, [:anthropic, :openai, :google, :openrouter]

  Or load it at runtime:

      Omni.Provider.load([:openrouter])

  Reads the API key from the `OPENROUTER_API_KEY` environment variable — no
  further configuration is needed if the variable is set.

  ## Configuration

  Override the default API key or base URL via application config:

      config :omni, Omni.Providers.OpenRouter,
        api_key: {:system, "MY_OPENROUTER_KEY"}

  Any key from the provider's `config/0` can be overridden: `:api_key`,
  `:base_url`. See `Omni.Provider` for details.

  OpenRouter wraps reasoning model output in a `reasoning_details` format
  rather than standard thinking blocks. This is handled automatically —
  reasoning data round-trips through `Omni.Message.private` in multi-turn
  conversations without any special handling.
  """

  alias Omni.Context

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://openrouter.ai/api",
      api_key: {:system, "OPENROUTER_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/openrouter.json")
  end

  @impl true
  def modify_body(%{"reasoning_effort" => effort} = body, context, _opts) do
    body
    |> Map.delete("reasoning_effort")
    |> Map.put("reasoning", %{"effort" => effort})
    |> attach_reasoning_details(context)
  end

  def modify_body(body, context, _opts) do
    attach_reasoning_details(body, context)
  end

  @impl true
  def modify_events(deltas, raw_event) do
    case extract_reasoning_details(raw_event) do
      [] -> deltas
      details -> deltas ++ [{:message, %{private: %{reasoning_details: details}}}]
    end
  end

  @impl true
  def authenticate(req, opts) do
    with {:ok, key} <- Omni.Provider.resolve_auth(opts.api_key) do
      {:ok, Req.Request.put_header(req, "authorization", "Bearer #{key}")}
    end
  end

  defp attach_reasoning_details(body, %Context{messages: messages}) do
    assistant_privates =
      messages
      |> Enum.filter(&match?(%{role: :assistant}, &1))
      |> Enum.map(& &1.private)

    {updated, _rest} =
      Enum.map_reduce(body["messages"] || [], assistant_privates, fn
        %{"role" => "assistant"} = msg, [private | rest] ->
          {maybe_put_reasoning_details(msg, private), rest}

        msg, privates ->
          {msg, privates}
      end)

    Map.put(body, "messages", updated)
  end

  defp maybe_put_reasoning_details(msg, %{reasoning_details: details})
       when is_list(details) and details != [] do
    Map.put(msg, "reasoning_details", details)
  end

  defp maybe_put_reasoning_details(msg, _), do: msg

  defp extract_reasoning_details(%{
         "choices" => [%{"delta" => %{"reasoning_details" => details}}]
       })
       when is_list(details) and details != [] do
    details
  end

  defp extract_reasoning_details(_), do: []
end
