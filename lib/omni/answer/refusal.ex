defmodule Omni.Answer.Refusal do
  @moduledoc """
  The model declined to answer a question.

  Any question can be refused; the others in the decision are still answered.
  OpenAI's Decisions API and OpenRouter's System One API report refusals.
  """

  defstruct []

  @typedoc "A refused question."
  @type t :: %__MODULE__{}

  @doc "Creates a refusal."
  @spec new(Enumerable.t()) :: t()
  def new(attrs \\ []), do: struct!(__MODULE__, attrs)
end
