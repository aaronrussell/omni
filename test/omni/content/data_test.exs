defmodule Omni.Content.DataTest do
  use ExUnit.Case, async: true

  alias Omni.Content.Data

  describe "new/1" do
    test "keeps a string-keyed map as is" do
      assert %Data{data: %{"subject" => "Refund", "amount" => 120}} =
               Data.new(%{"subject" => "Refund", "amount" => 120})
    end

    test "normalises through JSON: string keys, atoms as strings, structs encoded" do
      data =
        Data.new(%{ticket: %{plan: :enterprise, tags: [:billing, nil, true]}, on: ~D[2026-11-10]})

      assert data.data == %{
               "ticket" => %{"plan" => "enterprise", "tags" => ["billing", nil, true]},
               "on" => "2026-11-10"
             }
    end

    test "takes a keyword list, normalising its data" do
      assert %Data{data: %{"plan" => "pro"}} = Data.new(data: %{plan: :pro})
    end

    test "treats a map as the data, never as attributes" do
      assert %Data{data: %{"data" => %{"a" => 1}}} = Data.new(%{data: %{a: 1}})
    end

    test "raises when data is missing or not a plain map" do
      assert_raise KeyError, fn -> Data.new([]) end
      assert_raise FunctionClauseError, fn -> Data.new(data: [1, 2]) end
      assert_raise FunctionClauseError, fn -> Data.new(data: ~D[2026-11-10]) end
      assert_raise Protocol.UndefinedError, fn -> Data.new(~D[2026-11-10]) end
    end

    test "raises on a value JSON can't encode" do
      assert_raise Protocol.UndefinedError, fn -> Data.new(%{at: {1, 2}}) end

      attachment = Omni.Content.Attachment.new(source: {:base64, "AA=="}, media_type: "image/png")
      assert_raise Protocol.UndefinedError, fn -> Data.new(%{photo: attachment}) end
    end
  end
end
