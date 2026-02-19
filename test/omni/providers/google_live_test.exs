defmodule Omni.Providers.GoogleLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Omni.Provider
  alias Omni.Providers.Google
  alias Omni.SSE

  test "streams a real response from the Google Gemini API" do
    body = %{
      "contents" => [%{"role" => "user", "parts" => [%{"text" => "Say hello in one word."}]}],
      "generationConfig" => %{"maxOutputTokens" => 50}
    }

    {:ok, req} =
      Provider.new_request(
        Google,
        "/v1beta/models/gemini-2.0-flash-lite:streamGenerateContent?alt=sse",
        body
      )

    {:ok, resp} = Req.request(req)

    assert resp.status == 200
    assert %Req.Response.Async{} = resp.body

    events = resp.body |> SSE.stream() |> Enum.to_list()

    assert length(events) > 0

    # Google chunks have candidates arrays
    assert Enum.any?(events, &match?(%{"candidates" => [_ | _]}, &1))
  end
end
