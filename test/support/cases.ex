defmodule Omni.Test.Cases do
  @moduledoc false

  # Requests for the shape cases verify has no scenario for. Capture scripts
  # record them and tests replay them with the same request, as
  # `Omni.Test.Baseline.request/1` does for verify's scenarios.

  alias Omni.{Context, Decision, Message, Model, Provider}
  alias Omni.Dialects.OpenAICompletions

  @doc """
  The reference model each dialect's cases are recorded from: the dialect's
  home API. Completions is OpenAI's own `/chat/completions`, which no built-in
  speaks; local Ollama models aren't in the catalog.
  """
  @spec reference(atom()) :: Model.t()
  def reference(:anthropic_messages), do: get_model!(:anthropic, "claude-haiku-5-5")
  def reference(:openai_responses), do: get_model!(:openai, "gpt-6-luna")
  def reference(:google_gemini), do: get_model!(:google, "gemini-3.8-flash")
  def reference(:openai_decisions), do: get_model!(:openai, "gpt-6-luna")

  def reference(:openai_completions) do
    model = get_model!(:openai, "gpt-6-luna")
    {:ok, endpoint} = Provider.endpoint(model.provider, Omni.Dialects.OpenAIResponses)
    provider = model.provider
    provider = %{provider | dialects: Map.put(provider.dialects, OpenAICompletions, endpoint)}

    %{model | dialects: %{text: OpenAICompletions}, provider: provider}
  end

  def reference(:ollama_chat) do
    Model.new(
      id: "qwen3.8:27b-mlx",
      name: "qwen3.8:27b-mlx",
      provider: :ollama,
      dialects: %{text: Omni.Dialects.OllamaChat},
      thinking: true
    )
  end

  defp get_model!(provider, id) do
    {:ok, model} = Omni.get_model(provider, id)
    model
  end

  # Anthropic's documented trigger for a `redacted_thinking` block.
  @redacted_trigger "ANTHROPIC_MAGIC_STRING_TRIGGER_REDACTED_THINKING_46C9A13E193C177646C7398A98432ECCCE4C1253D5E2D82641AC0E52CC2876CB"

  @story "a 300-word story about a lighthouse keeper"

  @doc "The context (or decision) and options a case sends."
  @spec request(atom()) :: {Context.t() | Decision.t(), keyword()}

  # The cache scenario's 7k-token station table as the state, sent twice:
  # long enough for OpenAI's automatic prompt cache.
  def request(:decision_cache) do
    {%Context{system: table}, _opts} = Omni.Verify.Scenarios.request(:cache_usage)

    decision =
      Decision.new({table, [elevated: Omni.predicate("Is any station's elevation above 900 m?")]})

    {decision, [prompt_cache_key: "omni-decision-cache"]}
  end

  # Stops partway through a tool call: the note runs far past `max_tokens`.
  # Responses takes no fewer than 16 output tokens.
  def request(:tool_length) do
    question = Message.new("Use the save_note tool to save #{@story}. Call it straight away.")
    {Context.new(messages: [question], tools: [note_tool()]), [thinking: false, max_tokens: 40]}
  end

  def request(:length) do
    {Context.new("Write #{@story}."), [thinking: false, max_tokens: 20]}
  end

  def request(:redacted_thinking), do: {Context.new(@redacted_trigger), [thinking: :low]}

  # Thinking, then tool calls, then a tool round: kitchen_sink's tools and
  # question, pushed to reason first. At `:low`, Haiku 5.5 and gpt-6-luna
  # called the tools without reasoning.
  def request(:thinking_tools) do
    {context, _opts} = Omni.Verify.Scenarios.request(:kitchen_sink)
    system = "Before calling any tools, think through which calls you need and why."
    {%{context | system: system}, [thinking: :high]}
  end

  defp note_tool do
    Omni.tool(
      name: "save_note",
      description: "Saves a note",
      input_schema: %{
        type: "object",
        properties: %{text: %{type: "string", description: "The note's full text"}},
        required: ["text"]
      }
    )
  end
end
