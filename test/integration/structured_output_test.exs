defmodule Integration.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Omni.{Response, Schema}

  @valid_fixture "test/support/fixtures/synthetic/anthropic_json_valid.sse"
  @invalid_fixture "test/support/fixtures/synthetic/anthropic_json_invalid.sse"
  @not_json_fixture "test/support/fixtures/synthetic/anthropic_not_json.sse"
  @truncated_fixture "test/support/fixtures/synthetic/anthropic_json_truncated.sse"

  @output_schema Schema.object(
                   %{
                     city: Schema.string(),
                     temperature: Schema.number()
                   },
                   required: [:city, :temperature]
                 )

  defp stub_fixture(stub_name, fixture_path) do
    Req.Test.stub(stub_name, fn conn ->
      body = File.read!(fixture_path)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp stub_sequence(stub_name, fixtures) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub_name, fn conn ->
      call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      fixture = Enum.at(fixtures, call_num, List.last(fixtures))
      body = File.read!(fixture)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp model do
    {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
    model
  end

  describe "valid output" do
    test "response.output populated with decoded map" do
      stub_fixture(:so_valid, @valid_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Get weather for London",
                 api_key: "test-key",
                 plug: {Req.Test, :so_valid},
                 output: @output_schema
               )

      assert resp.stop_reason == :stop
      assert resp.output == %{city: "London", temperature: 18}
    end
  end

  describe "invalid then valid" do
    test "retry succeeds, response.output populated, 3 messages" do
      stub_sequence(:so_retry, [@invalid_fixture, @valid_fixture])

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Get weather for London",
                 api_key: "test-key",
                 plug: {Req.Test, :so_retry},
                 output: @output_schema
               )

      assert resp.stop_reason == :stop
      assert resp.output == %{city: "London", temperature: 18}
      # 3 messages: assistant (bad), user (retry), assistant (good)
      assert length(resp.messages) == 3
    end
  end

  describe "repeated invalid" do
    test "retries exhausted, response.output is nil" do
      stub_fixture(:so_exhausted, @invalid_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Get weather for London",
                 api_key: "test-key",
                 plug: {Req.Test, :so_exhausted},
                 output: @output_schema
               )

      assert resp.output == nil
      # 1 original + 3 retries = 4 assistant + 3 user = 7 messages
      assert length(resp.messages) == 7
    end
  end

  describe "not valid JSON" do
    test "retry on non-JSON, succeeds on second attempt" do
      stub_sequence(:so_not_json, [@not_json_fixture, @valid_fixture])

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Get weather for London",
                 api_key: "test-key",
                 plug: {Req.Test, :so_not_json},
                 output: @output_schema
               )

      assert resp.output == %{city: "London", temperature: 18}
      assert length(resp.messages) == 3
    end
  end

  describe "stop_reason: :length" do
    test "no retry, response.output is nil" do
      stub_fixture(:so_truncated, @truncated_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Get weather for London",
                 api_key: "test-key",
                 plug: {Req.Test, :so_truncated},
                 output: @output_schema
               )

      assert resp.output == nil
      assert resp.stop_reason == :length
      # Only 1 message, no retry
      assert length(resp.messages) == 1
    end
  end

  describe "no output option" do
    test "response.output is nil (existing behavior)" do
      stub_fixture(:so_no_opt, @valid_fixture)

      assert {:ok, %Response{} = resp} =
               Omni.generate_text(model(), "Get weather for London",
                 api_key: "test-key",
                 plug: {Req.Test, :so_no_opt}
               )

      assert resp.output == nil
    end
  end
end
