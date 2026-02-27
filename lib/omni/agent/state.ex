defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to `Omni.Agent` callbacks.

  This struct contains the fields that agent callback implementations can read
  and (via `assigns`) write. Internal server machinery (task tracking, tool
  decision state, etc.) is managed separately and not exposed to callbacks.

  ## Fields

    * `:model` — the `%Model{}` this agent is using
    * `:context` — the committed `%Context{}` (system prompt, messages, tools)
    * `:opts` — agent-level default inference options (keyword list)
    * `:status` — `:idle`, `:running`, or `:paused`
    * `:usage` — cumulative `%Usage{}` across all prompt rounds
    * `:assigns` — user-defined state (like Phoenix socket assigns)
    * `:step` — current step counter within the active prompt round

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
