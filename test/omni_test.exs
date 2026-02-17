defmodule OmniTest do
  use ExUnit.Case, async: true
  doctest Omni

  test "context/1 delegates to Context.new/1" do
    assert %Omni.Context{messages: [%Omni.Message{role: :user}]} = Omni.context("Hello")
  end

  test "message/1 delegates to Message.new/1" do
    assert %Omni.Message{role: :user, content: [%Omni.Content.Text{text: "Hi"}]} =
             Omni.message("Hi")
  end
end
