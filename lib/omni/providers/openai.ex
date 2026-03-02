defmodule Omni.Providers.OpenAI do
  @moduledoc """
  Provider for the OpenAI API, using the `Omni.Dialects.OpenAIResponses`
  dialect.
  """

  use Omni.Provider, dialect: Omni.Dialects.OpenAIResponses

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
    with {:ok, key} <- Omni.Provider.resolve_auth(opts.api_key) do
      {:ok, Req.Request.put_header(req, "authorization", "Bearer #{key}")}
    end
  end
end
