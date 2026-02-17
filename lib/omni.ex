defmodule Omni do
  @moduledoc """
  Elixir library for interacting with LLM APIs across multiple providers.
  """

  @doc "Creates a new `%Omni.Context{}` from a string, list of messages, keyword list, or map."
  defdelegate context(input), to: Omni.Context, as: :new

  @doc "Creates a new `%Omni.Message{}` from a string, keyword list, or map."
  defdelegate message(input), to: Omni.Message, as: :new
end
