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
end
