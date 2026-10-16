defmodule OmniTest do
  use ExUnit.Case, async: true
  doctest Omni

  alias Omni.{Context, Message, Model}

  describe "delegates" do
    test "get_model/2 delegates to Model.get/2" do
      {:ok, [%Model{id: model_id} | _]} = Model.list(:anthropic)
      assert {:ok, %Model{id: ^model_id}} = Omni.get_model(:anthropic, model_id)
    end

    test "get_model/2 returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nonexistent}} = Omni.get_model(:nonexistent, "any")
    end

    test "get_provider/1 delegates to Provider.get/1" do
      assert {:ok, %Omni.Provider{id: :anthropic}} = Omni.get_provider(:anthropic)
      assert {:error, {:unknown_provider, :nonexistent}} = Omni.get_provider(:nonexistent)
    end

    test "list_models/1 delegates to Model.list/1" do
      assert {:ok, models} = Omni.list_models(:anthropic)
      assert length(models) > 0
    end

    test "tool/1 delegates to Tool.new/1" do
      tool = Omni.tool(name: "greet", description: "Says hello", handler: &String.upcase/1)
      assert %Omni.Tool{name: "greet", description: "Says hello"} = tool
    end

    test "context/1 delegates to Context.new/1" do
      assert %Context{messages: [%Message{role: :user}]} = Omni.context("Hello")
    end

    test "message/1 delegates to Message.new/1" do
      assert %Message{role: :user, content: [%Omni.Content.Text{text: "Hi"}]} =
               Omni.message("Hi")
    end
  end
end
