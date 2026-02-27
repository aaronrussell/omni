defmodule Omni.Agent.State do
  @moduledoc false

  alias Omni.{Context, Model, Response, Usage}
  alias Omni.Content.{ToolResult, ToolUse}

  @type t :: %__MODULE__{
          module: module() | nil,
          model: Model.t(),
          context: Context.t(),
          opts: keyword(),
          status: :idle | :running | :paused,
          usage: Usage.t(),
          assigns: map(),
          step: non_neg_integer(),
          pending_messages: [Omni.Message.t()],
          next_prompt: term() | nil,
          prompt_opts: keyword(),
          listener: pid() | nil,
          step_task: {pid(), reference()} | nil,
          executor_task: {pid(), reference()} | nil,
          rejected_results: [ToolResult.t()],
          tool_timeout: timeout(),
          last_response: Response.t() | nil,
          paused_decision: paused_decision() | nil
        }

  # Snapshot of the tool decision loop at the point it was interrupted by
  # `{:pause, state}` from `handle_tool_call`. Captures everything needed
  # to resume from that exact position when `Agent.resume/2` is called.
  # Rejected results are stored on `state.rejected_results` (not here).
  @type paused_decision :: %{
          # The tool_use awaiting a human decision (shown in the :pause event)
          tool_use: ToolUse.t(),
          # Tool uses after the paused one, not yet presented to handle_tool_call
          remaining: [ToolUse.t()],
          # Already-approved tool uses (reversed — built with prepend)
          approved: [ToolUse.t()],
          # Name → Tool lookup, built once at decision phase start for the executor
          tool_map: %{String.t() => Omni.Tool.t()}
        }

  defstruct [
    :module,
    :model,
    :context,
    :opts,
    status: :idle,
    usage: %Usage{},
    assigns: %{},
    step: 0,
    pending_messages: [],
    next_prompt: nil,
    prompt_opts: [],
    listener: nil,
    step_task: nil,
    executor_task: nil,
    rejected_results: [],
    tool_timeout: 5_000,
    last_response: nil,
    paused_decision: nil
  ]
end
