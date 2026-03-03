defmodule Omni.NDJSONTest do
  use ExUnit.Case, async: true

  alias Omni.NDJSON

  describe "stream/1" do
    test "single line in one chunk" do
      chunks = ["{\"type\":\"ping\"}\n"]
      assert [%{"type" => "ping"}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "multiple lines in one chunk" do
      chunks = ["{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n"]

      assert [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}] =
               chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "line split across two chunks" do
      chunks = [
        "{\"hel",
        "lo\":true}\n"
      ]

      assert [%{"hello" => true}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "line split across three chunks" do
      chunks = [
        "{\"a\":",
        "1,\"b\":",
        "2}\n"
      ]

      assert [%{"a" => 1, "b" => 2}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "empty lines are skipped" do
      chunks = ["\n\n{\"ok\":true}\n\n"]
      assert [%{"ok" => true}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "invalid JSON lines are skipped" do
      chunks = ["not json\n{\"valid\":true}\n"]
      assert [%{"valid" => true}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "empty chunks produce no events" do
      chunks = ["", "", "{\"ok\":true}\n", ""]
      assert [%{"ok" => true}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "buffer flushed at stream end" do
      # No trailing newline — should still emit the buffered line
      chunks = ["{\"flushed\":true}"]
      assert [%{"flushed" => true}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "buffer flush skips incomplete JSON" do
      chunks = ["{\"incomplete\":"]
      assert [] = chunks |> NDJSON.stream() |> Enum.to_list()
    end

    test "multiple chunks without trailing newlines" do
      chunks = [
        "{\"a\":1}\n{\"b\":",
        "2}"
      ]

      assert [%{"a" => 1}, %{"b" => 2}] = chunks |> NDJSON.stream() |> Enum.to_list()
    end
  end
end
