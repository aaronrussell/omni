defmodule Omni.VerifyTest do
  use ExUnit.Case, async: true

  alias Omni.Verify

  @text_fixture "test/support/fixtures/sse/anthropic_text.sse"
  @thinking_fixture "test/support/fixtures/sse/anthropic_thinking.sse"
  @tool_use_fixture "test/support/fixtures/sse/anthropic_tool_use.sse"
  @error_fixture "test/support/fixtures/synthetic/anthropic_error.sse"

  defp stub_fixture(stub_name, fixture_file) do
    Req.Test.stub(stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, File.read!(fixture_file))
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
    model
  end

  defp run_one(scenario, fixture) do
    stub = :"verify_#{scenario}_#{System.unique_integer([:positive])}"
    stub_fixture(stub, fixture)
    [result] = Verify.run(model(), [scenario], api_key: "test-key", plug: {Req.Test, stub})
    result
  end

  describe "select/1" do
    test "defaults without options" do
      assert {:ok, scenarios} = Verify.select()
      assert scenarios == Verify.defaults()
    end

    test "only gives exactly the listed scenarios, in run order" do
      assert {:ok, [:text, :pdf]} = Verify.select(only: [:pdf, :text])
    end

    test "add and skip adjust the defaults" do
      assert {:ok, scenarios} = Verify.select(add: [:cache_usage, :image], skip: [:no_thinking])

      assert scenarios == [
               :text,
               :thinking,
               :tool_use,
               :structured_output,
               :image,
               :cache_usage
             ]
    end

    test "unknown names are an error" do
      assert {:error, {:unknown_scenarios, ["bogus", :nope]}} =
               Verify.select(only: ["bogus"], skip: [:nope])
    end
  end

  describe "run/3" do
    test "text passes on a text response" do
      assert %{scenario: :text, status: :pass, summary: summary} = run_one(:text, @text_fixture)
      assert is_binary(summary) and summary != ""
    end

    test "a failed request carries the request body" do
      assert %{status: :fail, error: error, request: request} = run_one(:text, @error_fixture)
      assert error =~ "error"
      assert request["model"] == "claude-haiku-4-5"
    end

    test "thinking passes with thinking and fails without" do
      assert %{status: :pass} = run_one(:thinking, @thinking_fixture)
      assert %{status: :fail, error: "no thinking"} = run_one(:thinking, @text_fixture)
    end

    test "no_thinking passes without thinking and fails with" do
      assert %{status: :pass} = run_one(:no_thinking, @text_fixture)

      assert %{status: :fail, error: "thinking blocks present", request: request} =
               run_one(:no_thinking, @thinking_fixture)

      assert is_map(request)
    end

    test "tool_use passes on a get_weather tool use" do
      assert %{status: :pass, summary: "get_weather(" <> _} =
               run_one(:tool_use, @tool_use_fixture)
    end

    test "a crashing scenario fails and the run continues" do
      broken = %Omni.Model{id: "broken", name: "broken"}
      stub_fixture(:verify_crash, @text_fixture)
      test_pid = self()

      results =
        Verify.run(broken, [:text, :thinking],
          api_key: "test-key",
          plug: {Req.Test, :verify_crash},
          on_result: &send(test_pid, {:result, &1.scenario})
        )

      assert [%{status: :fail, error: "raised " <> _}, %{status: :fail}] = results
      assert_received {:result, :text}
      assert_received {:result, :thinking}
    end
  end
end
