defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to all `Omni.Agent` callbacks.

  Internal server machinery (task tracking, tool decision state, process refs)
  is managed separately and not exposed to callbacks.

  Fields fall into two groups:

  **Configuration** — set at startup, stable for the agent's lifetime:

    * `:model` — the `%Model{}` this agent is using
    * `:context` — the committed `%Context{}` (system prompt, messages, tools).
      Only includes messages from completed prompt rounds — in-progress messages
      are not visible here until the round finishes
    * `:opts` — agent-level default inference options (keyword list), passed to
      `stream_text` each step

  **Session** — change during operation:

    * `:status` — `:idle`, `:running`, or `:paused`
    * `:usage` — cumulative `%Usage{}` across all prompt rounds. Reset by
      `Omni.Agent.clear/1`
    * `:assigns` — user-defined state, like Phoenix socket assigns. Persists
      across callbacks and prompt rounds. Set initial values in `init/1`,
      update in any callback via `%{state | assigns: ...}`
    * `:step` — current step counter within the active prompt round. Resets
      to `0` when a new round begins. Useful for step-based policies in
      callbacks (e.g. rejecting tools after a threshold)
  """

  alias Omni.{Context, Model, Usage}

  @typedoc "The public agent state passed to all callbacks."
  @type t :: %__MODULE__{
          model: Model.t(),
          context: Context.t(),
          opts: keyword(),
          status: :idle | :running | :paused,
          usage: Usage.t(),
          assigns: map(),
          step: non_neg_integer()
        }

  defstruct [
    :model,
    :context,
    :opts,
    status: :idle,
    usage: %Usage{},
    assigns: %{},
    step: 0
  ]
end
