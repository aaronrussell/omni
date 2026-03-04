defmodule Omni.Content.Attachment do
  @moduledoc """
  An attachment content block for binary content such as images, PDFs, and
  other media.

  Sources use tagged tuples: `{:base64, data}` for inline binary data, or
  `{:url, url}` for remotely-hosted content.

  The `:opts` field is reserved for provider-specific metadata (e.g.
  citations, titles, file IDs) that dialects may read when encoding.
  """

  @enforce_keys [:source, :media_type]
  defstruct [:source, :media_type, :description, opts: %{}]

  @typedoc "An attachment source — inline base64 data or a remote URL."
  @type source :: {:base64, binary()} | {:url, String.t()}

  @typedoc "Binary content with a source, media type, and optional description."
  @type t :: %__MODULE__{
          source: source(),
          media_type: String.t(),
          description: String.t() | nil,
          opts: map()
        }

  @doc "Creates a new attachment content block from a keyword list or map."
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
