defmodule Omni.Agent.State do
  @moduledoc false

  alias Omni.{Context, Model, Usage}

  @type t :: %__MODULE__{
          module: module() | nil,
          model: Model.t(),
          context: Context.t(),
          opts: keyword(),
          status: :idle | :running,
          usage: Usage.t(),
          assigns: map(),
          step: non_neg_integer(),
          pending_messages: [Omni.Message.t()],
          pending_prompt: nil,
          prompt_opts: keyword(),
          listener: pid() | nil,
          step_task: {pid(), reference()} | nil
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
    pending_prompt: nil,
    prompt_opts: [],
    listener: nil,
    step_task: nil
  ]
end
