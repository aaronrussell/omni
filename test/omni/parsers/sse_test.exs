defmodule Omni.Parsers.SSETest do
  use ExUnit.Case, async: true

  alias Omni.Parsers.SSE

  describe "stream/1" do
    test "single event in one chunk" do
      chunks = ["data: {\"type\":\"ping\"}\n\n"]
      assert [%{"type" => "ping"}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "multiple events in one chunk" do
      chunks = [
        "data: {\"id\":1}\n\ndata: {\"id\":2}\n\ndata: {\"id\":3}\n\n"
      ]

      assert [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}] =
               chunks |> SSE.stream() |> Enum.to_list()
    end

    test "event split across two chunks (mid-line)" do
      chunks = [
        "data: {\"hel",
        "lo\":true}\n\n"
      ]

      assert [%{"hello" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "event split across two chunks (mid-delimiter)" do
      chunks = [
        "data: {\"a\":1}\n",
        "\ndata: {\"b\":2}\n\n"
      ]

      assert [%{"a" => 1}, %{"b" => 2}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "[DONE] terminates stream cleanly" do
      chunks = [
        "data: {\"id\":1}\n\ndata: [DONE]\n\n"
      ]

      assert [%{"id" => 1}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "[DONE] with trailing events ignores them" do
      chunks = [
        "data: {\"id\":1}\n\ndata: [DONE]\n\ndata: {\"id\":2}\n\n"
      ]

      assert [%{"id" => 1}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "comment-only events are filtered" do
      chunks = [
        ":ping\n\ndata: {\"ok\":true}\n\n:keepalive\n\n"
      ]

      assert [%{"ok" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "multiple data: lines joined with newline" do
      chunks = [
        "data: {\"multi\":\ndata: true}\n\n"
      ]

      assert [%{"multi" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "empty chunks produce no events" do
      chunks = ["", "", "data: {\"ok\":true}\n\n", ""]
      assert [%{"ok" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "event: type lines are ignored" do
      chunks = [
        "event: content_block_delta\ndata: {\"type\":\"delta\"}\n\n"
      ]

      assert [%{"type" => "delta"}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "non-JSON data lines are skipped gracefully" do
      chunks = [
        "data: not json\n\ndata: {\"valid\":true}\n\n"
      ]

      assert [%{"valid" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "id: and retry: lines are ignored" do
      chunks = [
        "id: 123\nretry: 5000\ndata: {\"ok\":true}\n\n"
      ]

      assert [%{"ok" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end

    test "empty data lines produce no events" do
      chunks = ["data:\n\ndata: {\"ok\":true}\n\n"]
      assert [%{"ok" => true}] = chunks |> SSE.stream() |> Enum.to_list()
    end
  end
end
