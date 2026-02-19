defmodule Omni.Providers.OpenAI do
  @moduledoc """
  Provider for the OpenAI Chat Completions API.

  Authenticates via the `Authorization: Bearer <key>` header.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

  @impl true
  def config do
    %{
      base_url: "https://api.openai.com",
      api_key: {:system, "OPENAI_API_KEY"}
    }
  end

  @impl true
  def models do
    Omni.Provider.load_models(__MODULE__, "priv/models/openai.json")
  end

  @impl true
  def authenticate(req, opts) do
    with {:ok, key} <- Omni.Provider.resolve_auth(Keyword.get(opts, :api_key)) do
      {:ok, Req.Request.put_header(req, "authorization", "Bearer #{key}")}
    end
  end
end
