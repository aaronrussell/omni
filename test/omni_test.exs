defmodule OmniTest do
  use ExUnit.Case
  doctest Omni

  test "greets the world" do
    assert Omni.hello() == :world
  end
end
