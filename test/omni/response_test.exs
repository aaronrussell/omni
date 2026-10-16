defmodule Omni.ResponseTest do
  use ExUnit.Case, async: true

  alias Omni.{Message, Response, Usage}
  alias Omni.Test.Fixtures

  describe "new/1" do
    test "creates response from keyword list with all fields" do
      message = Message.new(role: :assistant, content: "Hello")
      model = Fixtures.model(id: "test-model", name: "Test")
      usage = Usage.new(input_tokens: 10, output_tokens: 5)

      response =
        Response.new(
          message: message,
          model: model,
          messages: [message],
          usage: usage,
          stop_reason: :stop,
          error: nil,
          raw: nil
        )

      assert response.message == message
      assert response.model == model
      assert response.usage == usage
      assert response.messages == [message]
      assert response.stop_reason == :stop
      assert response.error == nil
      assert response.raw == nil
    end

    test "error and raw default to nil, messages and usage have defaults" do
      message = Message.new(role: :assistant, content: "Hello")
      model = Fixtures.model(id: "test-model", name: "Test")

      response = Response.new(message: message, model: model, stop_reason: :stop)

      assert response.error == nil
      assert response.raw == nil
      assert response.messages == []
      assert response.usage == %Usage{}
    end

    test "raises on missing enforced keys" do
      assert_raise ArgumentError, fn ->
        Response.new(message: Message.new("hi"))
      end
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Response.new(
          message: Message.new("hi"),
          model: Fixtures.model(id: "t", name: "T"),
          stop_reason: :stop,
          bogus: true
        )
      end
    end
  end
end
