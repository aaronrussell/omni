defmodule Omni.Content.AttachmentTest do
  use ExUnit.Case, async: true

  alias Omni.Content.Attachment

  describe "new/1" do
    test "creates with URL source" do
      attachment =
        Attachment.new(source: {:url, "https://example.com/img.png"}, media_type: "image/png")

      assert %Attachment{source: {:url, "https://example.com/img.png"}, media_type: "image/png"} =
               attachment
    end

    test "creates with base64 source" do
      attachment = Attachment.new(source: {:base64, "abc123"}, media_type: "image/jpeg")
      assert %Attachment{source: {:base64, "abc123"}, media_type: "image/jpeg"} = attachment
    end

    test "meta defaults to empty map" do
      attachment = Attachment.new(source: {:url, "https://example.com"}, media_type: "image/png")
      assert attachment.meta == %{}
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Attachment.new(
          source: {:url, "https://example.com"},
          media_type: "image/png",
          bogus: true
        )
      end
    end
  end

  describe "new/2" do
    test "takes a source and media type" do
      assert Attachment.new({:base64, "abc123"}, "image/jpeg") ==
               Attachment.new(source: {:base64, "abc123"}, media_type: "image/jpeg")
    end
  end

  test "the Omni delegates build the same structs" do
    assert Omni.attachment({:url, "https://example.com"}, "image/png") ==
             Attachment.new({:url, "https://example.com"}, "image/png")

    assert Omni.attachment(source: {:url, "https://example.com"}, media_type: "image/png") ==
             Attachment.new({:url, "https://example.com"}, "image/png")

    assert Omni.tool_result(tool_use_id: "tu_1", name: "x", content: "ok") ==
             Omni.Content.ToolResult.new(tool_use_id: "tu_1", name: "x", content: "ok")
  end
end
