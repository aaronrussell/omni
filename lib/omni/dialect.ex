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
  @callback handle_path(Model.t(), keyword()) :: String.t()

  @doc "Builds the request body from a model, context, and validated options."
  @callback handle_body(Model.t(), Context.t(), keyword()) :: map()

  @doc "Parses a raw SSE event map into a list of delta tuples."
  @callback handle_event(map()) :: [{atom(), map()}]
end
