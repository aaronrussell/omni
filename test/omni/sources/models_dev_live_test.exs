defmodule Omni.Sources.ModelsDevLiveTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Omni.Sources.ModelsDev

  @cache_file "models_dev.json"

  defp catalog_body(model_ids) do
    models =
      Map.new(model_ids, fn id ->
        {id,
         %{
           "id" => id,
           "name" => id,
           "tool_call" => true,
           "modalities" => %{"input" => ["text"], "output" => ["text"]},
           "cost" => %{"input" => 1.0, "output" => 2.0},
           "limit" => %{"context" => 100_000, "output" => 8192}
         }}
      end)

    JSON.encode!(%{
      "livetest" => %{
        "id" => "livetest",
        "npm" => "@ai-sdk/openai-compatible",
        "models" => models
      }
    })
  end

  # A plug serving the given body, notifying the test process per request.
  defp serve(body, status \\ 200) do
    parent = self()

    fn conn ->
      send(parent, :fetched)
      Plug.Conn.send_resp(conn, status, body)
    end
  end

  # A plug that must never be reached; fails the test loudly if it is.
  defp poisoned do
    parent = self()

    fn conn ->
      send(parent, :fetched)
      Req.Test.transport_error(conn, :econnrefused)
    end
  end

  defp transport_error(reason) do
    parent = self()

    fn conn ->
      send(parent, :fetched)
      Req.Test.transport_error(conn, reason)
    end
  end

  defp write_cache(tmp_dir, body, age_seconds \\ 0) do
    path = Path.join(tmp_dir, @cache_file)
    File.write!(path, body)
    if age_seconds > 0, do: File.touch!(path, System.os_time(:second) - age_seconds)
    path
  end

  defp fetch_live(tmp_dir, plug, opts \\ []) do
    ModelsDev.fetch(:livetest, Keyword.merge([live: true, cache_dir: tmp_dir, plug: plug], opts))
  end

  defp model_ids({:ok, _provider, models}), do: Enum.map(models, & &1.id)

  describe "resilience ladder" do
    test "fresh cache is used without touching the network", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, catalog_body(["cached-model"]))

      result = fetch_live(tmp_dir, poisoned())

      assert model_ids(result) == ["cached-model"]
      refute_received :fetched
    end

    test "missing cache fetches and writes the cache atomically", %{tmp_dir: tmp_dir} do
      body = catalog_body(["fetched-model"])

      result = fetch_live(tmp_dir, serve(body))

      assert model_ids(result) == ["fetched-model"]
      assert_received :fetched
      assert File.read!(Path.join(tmp_dir, @cache_file)) == body
      assert Path.wildcard(Path.join(tmp_dir, "*.tmp.*")) == []
    end

    test "stale cache is refetched and overwritten", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, catalog_body(["stale-model"]), 100_000)
      body = catalog_body(["fresh-model"])

      result = fetch_live(tmp_dir, serve(body))

      assert model_ids(result) == ["fresh-model"]
      assert File.read!(Path.join(tmp_dir, @cache_file)) == body
    end

    test "fetch failure falls back to the stale cache with a warning", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, catalog_body(["stale-model"]), 100_000)

      {result, log} = with_log(fn -> fetch_live(tmp_dir, transport_error(:timeout)) end)

      assert model_ids(result) == ["stale-model"]
      assert log =~ "using stale cache"
    end

    test "fetch failure without a cache falls back to the bundled snapshot", %{tmp_dir: tmp_dir} do
      {result, log} =
        with_log(fn ->
          ModelsDev.fetch(:openai,
            live: true,
            cache_dir: tmp_dir,
            plug: transport_error(:timeout)
          )
        end)

      assert log =~ "falling back to the bundled snapshot"
      assert result == ModelsDev.fetch(:openai, [])
    end
  end

  describe "cache handling" do
    test "cache write failure warns and proceeds with fetched data", %{tmp_dir: tmp_dir} do
      # A regular file where the cache dir should be makes mkdir_p fail.
      blocked = Path.join(tmp_dir, "blocked")
      File.write!(blocked, "in the way")

      {result, log} =
        with_log(fn ->
          fetch_live(blocked, serve(catalog_body(["fetched-model"])))
        end)

      assert model_ids(result) == ["fetched-model"]
      assert log =~ "could not write live-catalog cache"
    end

    test "corrupt cache is treated as missing and healed by the next fetch", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, "not json")
      body = catalog_body(["fetched-model"])

      {result, log} = with_log(fn -> fetch_live(tmp_dir, serve(body)) end)

      assert model_ids(result) == ["fetched-model"]
      assert log =~ "ignoring unreadable live-catalog cache"
      assert File.read!(Path.join(tmp_dir, @cache_file)) == body
    end

    test "a fetched body that is not a JSON map is never cached", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, catalog_body(["stale-model"]), 100_000)

      {result, log} = with_log(fn -> fetch_live(tmp_dir, serve("garbage")) end)

      assert model_ids(result) == ["stale-model"]
      assert log =~ "using stale cache"
      assert File.read!(Path.join(tmp_dir, @cache_file)) == catalog_body(["stale-model"])
    end

    test "a non-200 response is a fetch failure", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, catalog_body(["stale-model"]), 100_000)

      {result, log} = with_log(fn -> fetch_live(tmp_dir, serve("", 503)) end)

      assert model_ids(result) == ["stale-model"]
      assert log =~ "http_status, 503"
    end

    test "cache_ttl: 0 always fetches", %{tmp_dir: tmp_dir} do
      write_cache(tmp_dir, catalog_body(["cached-model"]))

      result = fetch_live(tmp_dir, serve(catalog_body(["fetched-model"])), cache_ttl: 0)

      assert model_ids(result) == ["fetched-model"]
      assert_received :fetched
    end
  end

  describe "memoization and opts" do
    test "one fetch serves every provider in a load pass", %{tmp_dir: tmp_dir} do
      plug = serve(catalog_body(["fetched-model"]))

      Omni.Source.with_cache(fn ->
        assert {:ok, _, _} = fetch_live(tmp_dir, plug)
        assert {:ok, _, _} = fetch_live(tmp_dir, plug)
      end)

      assert_received :fetched
      refute_received :fetched
    end

    test "live: false ignores cache opts and never dials out", %{tmp_dir: tmp_dir} do
      result =
        ModelsDev.fetch(:openai, cache_dir: tmp_dir, cache_ttl: 0, plug: poisoned())

      assert result == ModelsDev.fetch(:openai, [])
      refute_received :fetched
      refute File.exists?(Path.join(tmp_dir, @cache_file))
    end

    test "live opts survive the loader's source resolution path", %{tmp_dir: tmp_dir} do
      {provider, models} =
        Omni.Provider.Loader.assemble(:livetest,
          base_url: "https://api.test.com/v1",
          source: {ModelsDev, live: true, cache_dir: tmp_dir, plug: serve(catalog_body(["e2e"]))}
        )

      assert Enum.map(models, & &1.id) == ["e2e"]
      assert Enum.all?(models, &(&1.provider == provider))
      assert provider.dialects == %{text: [Omni.Dialects.OpenAICompletions]}
    end
  end
end
