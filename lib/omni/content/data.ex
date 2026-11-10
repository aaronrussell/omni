defmodule Omni.Content.Data do
  @moduledoc """
  A data content block: structured data sent to the model as JSON.

  Used in decisions, as part of the state or of a question's instructions
  (see `Omni.Decision`). Not a message content block.

      Omni.Content.Data.new(%{ticket: %{subject: "Refund", plan: :enterprise}})
      #=> %Omni.Content.Data{data: %{"ticket" => %{"subject" => "Refund", "plan" => "enterprise"}}}

  `new/1` passes the map through JSON, so the struct holds exactly what the
  model sees: string keys, atoms as strings, and any struct with a
  `JSON.Encoder` implementation (such as `Date`) in its JSON form. A value
  JSON can't encode raises here rather than when the request is sent.
  """

  @enforce_keys [:data]
  defstruct [:data]

  @typedoc "Structured data, as the JSON-decoded map sent to the model."
  @type t :: %__MODULE__{data: map()}

  @doc """
  Creates a data block from the data map itself, or from a keyword list
  (`data: map`), normalising the map through JSON.

      Omni.Content.Data.new(%{plan: :pro})
      Omni.Content.Data.new(data: %{plan: :pro})

  A map is always the data, never attributes (unlike `Omni.Content.Text.new/1`),
  so `new(%{data: x})` builds `%{"data" => x}`.

  Raises if `:data` is missing, is not a plain map, or holds a value JSON
  can't encode.
  """
  @spec new(map() | Enumerable.t()) :: t()
  def new(data) when is_map(data) and not is_struct(data), do: new(data: data)

  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.update!(:data, &normalise/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp normalise(data) when is_map(data) and not is_struct(data),
    do: data |> JSON.encode!() |> JSON.decode!()
end
