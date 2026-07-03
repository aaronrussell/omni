defmodule Omni.Test.StubSource do
  @moduledoc false

  # A test model source driven entirely by its opts, so it can be injected as
  # plain config data: `source: {Omni.Test.StubSource, return: ..., notify: ...}`.
  #
  #   * `:return` — the value fetch/2 returns (default `{:ok, []}`)
  #   * `:notify` — a pid to send `{:fetch, module, opts}` to on every call

  @behaviour Omni.Source

  @impl Omni.Source
  def fetch(module, opts) do
    if pid = opts[:notify], do: send(pid, {:fetch, module, opts})
    Keyword.get(opts, :return, {:ok, []})
  end
end
