defmodule Omni.Content.Attachment do
  @moduledoc """
  An attachment content block: an image, a PDF or other binary content.

  A model takes only the media it supports (see `:input_modalities` on
  `Omni.Model`); a request with an attachment it can't take is an error
  before anything is sent.

  ```elixir
  Omni.attachment({:base64, Base.encode64(File.read!("photo.png"))}, "image/png")
  Omni.attachment({:url, "https://example.com/report.pdf"}, "application/pdf")
  ```

  ## Struct fields

  - `:source` - where the content is: `{:base64, data}` for inline
    base64-encoded data, or `{:url, url}` for content hosted elsewhere
  - `:media_type` - the MIME type, such as `"image/png"` or
    `"application/pdf"`
  - `:meta` - a map for your application's own data, such as a filename or
    a label for a UI. Omni never reads it or sends it to a provider
  """

  @enforce_keys [:source, :media_type]
  defstruct [:source, :media_type, meta: %{}]

  @typedoc "An attachment source: inline base64 data or a remote URL."
  @type source :: {:base64, binary()} | {:url, String.t()}

  @typedoc "Binary content with a source, media type, and optional application metadata."
  @type t :: %__MODULE__{
          source: source(),
          media_type: String.t(),
          meta: map()
        }

  @doc """
  Creates a new attachment content block from a keyword list or map.

  ```elixir
  Attachment.new(source: {:url, "https://example.com/cat.png"}, media_type: "image/png", meta: %{name: "cat.png"})
  ```
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Creates a new attachment content block from a source and media type.

  ```elixir
  Attachment.new({:base64, Base.encode64(File.read!("photo.png"))}, "image/png")
  Attachment.new({:url, "https://example.com/report.pdf"}, "application/pdf")
  ```
  """
  @spec new(source(), String.t()) :: t()
  def new(source, media_type), do: new(source: source, media_type: media_type)
end
