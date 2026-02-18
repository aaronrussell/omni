defmodule Omni.Dialect do
  @moduledoc """
  Behaviour for wire format translation between Omni types and provider APIs.

  A dialect handles the pure data transformation layer: building request bodies
  from Omni structs and parsing streaming events into normalized delta tuples.
  Each dialect corresponds to a specific API format (e.g. Anthropic Messages,
  OpenAI Chat Completions).
  """

  alias Omni.{Context, Model}

  @doc "Returns a Peri schema map for dialect-specific options."
  @callback option_schema() :: map()

  @doc "Returns the URL path for the given model."
  @callback build_path(Model.t()) :: String.t()

  @doc "Builds the request body from a model, context, and validated options."
  @callback build_body(Model.t(), Context.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Parses a raw SSE event map into a delta tuple, or nil to skip."
  @callback parse_event(map()) :: {atom(), map()} | nil
end
