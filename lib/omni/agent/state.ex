defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to all `Omni.Agent` callbacks.

  Internal server machinery (task tracking, tool decision state, process refs)
  is managed separately and not exposed to callbacks.

  Fields fall into two groups:

  **Configuration** — set at startup, changeable via `set_state/2,3`:

    * `:model` — the `%Model{}` this agent is using
    * `:system` — the system prompt string (or `nil`)
    * `:tools` — list of `%Tool{}` structs available to the model
    * `:opts` — agent-level default inference options (keyword list), passed to
      `stream_text` each step

  **Session** — change during operation:

    * `:tree` — `%MessageTree{}` containing the full conversation tree.
      Messages are pushed incrementally during a round, so the tree reflects
      the in-progress conversation including the current round's messages
    * `:usage` — cumulative `%Usage{}` across the entire session, including
      abandoned branches. Accumulates automatically every step; read-only
    * `:meta` — user metadata map (title, tags, custom domain data). Set initial
      values via `:meta` start option, update via `set_state/2,3`
    * `:private` — runtime state (PIDs, ETS refs, closures). Not persisted.
      Set initial values in `init/1`, update in any callback via
      `%{state | private: ...}`
    * `:status` — `:idle`, `:running`, `:paused`, or `:error`
    * `:step` — current step counter within the active prompt round. Resets
      to `0` when a new round begins. Useful for step-based policies in
      callbacks (e.g. rejecting tools after a threshold)
  """

  alias Omni.{MessageTree, Model, Tool, Usage}

  @typedoc "The public agent state passed to all callbacks."
  @type t :: %__MODULE__{
          model: Model.t(),
          system: String.t() | nil,
          tools: [Tool.t()],
          tree: MessageTree.t(),
          usage: Usage.t(),
          opts: keyword(),
          meta: map(),
          private: map(),
          status: :idle | :running | :paused | :error,
          step: non_neg_integer()
        }

  defstruct [
    :model,
    :opts,
    system: nil,
    tools: [],
    tree: %MessageTree{},
    usage: %Usage{},
    meta: %{},
    private: %{},
    status: :idle,
    step: 0
  ]
end
