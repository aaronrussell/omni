defmodule Omni.Providers.OpenRouter do
  @moduledoc """
  Provider for the OpenRouter API.

  OpenRouter is a meta-provider that routes requests to many LLM backends
  using the OpenAI Chat Completions wire format. Authenticates via the
  `Authorization: Bearer <key>` header.
  """

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
  def modify_body(%{"reasoning_effort" => effort} = body, _context, _opts) do
    mapped = if effort == "max", do: "xhigh", else: effort

    body
    |> Map.delete("reasoning_effort")
    |> Map.put("reasoning", %{"effort" => mapped})
  end

  def modify_body(body, _context, _opts), do: body

  @impl true
  def authenticate(req, opts) do
    with {:ok, key} <- Omni.Provider.resolve_auth(opts.api_key) do
      {:ok, Req.Request.put_header(req, "authorization", "Bearer #{key}")}
    end
  end
end
