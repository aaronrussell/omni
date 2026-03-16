defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to all `Omni.Agent` callbacks.

  Internal server machinery (task tracking, tool decision state, process refs)
  is managed separately and not exposed to callbacks.

  Fields fall into two groups:

  **Configuration** — set at startup, changeable via `configure/2,3`:

    * `:model` — the `%Model{}` this agent is using
    * `:system` — the system prompt string (or `nil`)
    * `:tools` — list of `%Tool{}` structs available to the model
    * `:opts` — agent-level default inference options (keyword list), passed to
      `stream_text` each step

  **Session** — change during operation:

    * `:session_id` — unique session identifier. Generated at startup, changes
      on `Omni.Agent.clear/1`
    * `:tree` — `%MessageTree{}` containing the full conversation tree. Only
      includes messages from completed prompt rounds — in-progress messages
      are not visible here until the round finishes
    * `:meta` — serializable user metadata (title, tags, custom domain data).
      Persisted by storage (Layer 3). Set initial values via `:meta` start
      option, update via `configure/2,3`
    * `:private` — runtime state (PIDs, ETS refs, closures). Not persisted.
      Set initial values in `init/1`, update in any callback via
      `%{state | private: ...}`
    * `:status` — `:idle`, `:running`, or `:paused`
    * `:step` — current step counter within the active prompt round. Resets
      to `0` when a new round begins. Useful for step-based policies in
      callbacks (e.g. rejecting tools after a threshold)
  """

  alias Omni.{MessageTree, Model, Tool}

  @typedoc "The public agent state passed to all callbacks."
  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          model: Model.t(),
          system: String.t() | nil,
          tools: [Tool.t()],
          tree: MessageTree.t(),
          opts: keyword(),
          meta: map(),
          private: map(),
          status: :idle | :running | :paused,
          step: non_neg_integer()
        }

  defstruct [
    :session_id,
    :model,
    :opts,
    system: nil,
    tools: [],
    tree: %MessageTree{},
    meta: %{},
    private: %{},
    status: :idle,
    step: 0
  ]
end
