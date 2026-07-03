defmodule Omni.ProviderSourceTest do
  # async: false — these tests mutate global application env (`:models` and
  # per-module `source:` config) that load_models/2 reads.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Omni.Provider
  alias Omni.Test.StubSource

  defmodule CustomProvider do
    use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

    @impl true
    def config, do: %{base_url: "https://api.custom.test", api_key: nil}
  end

  defmodule MemoSource do
    @behaviour Omni.Source

    @impl Omni.Source
    def fetch(_module, opts) do
      value = Omni.Source.memo({__MODULE__, :value}, fn -> :erlang.unique_integer() end)
      send(opts[:notify], {:memo_value, value})
      {:ok, []}
    end
  end

  defmodule LoadingProviderA do
    use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

    @impl true
    def config, do: %{base_url: "https://a.test", api_key: nil}

    @impl true
    def models, do: Omni.Provider.load_models(__MODULE__)
  end

  defmodule LoadingProviderB do
    use Omni.Provider, dialect: Omni.Dialects.OpenAICompletions

    @impl true
    def config, do: %{base_url: "https://b.test", api_key: nil}

    @impl true
    def models, do: Omni.Provider.load_models(__MODULE__)
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:omni, :models)
      Application.delete_env(:omni, CustomProvider)
    end)
  end

  defp marker(id) do
    Provider.build_model(CustomProvider, %{"id" => id, "name" => id})
  end

  defp stub(return), do: {StubSource, return: return}

  describe "source resolution ladder" do
    test "defaults to the ModelsDev source with no configuration" do
      models = Provider.load_models(Omni.Providers.Anthropic)

      assert [%Omni.Model{} | _] = models
      assert Enum.all?(models, &(&1.provider == Omni.Providers.Anthropic))
    end

    test "global config source is used" do
      Application.put_env(:omni, :models, source: stub({:ok, [marker("global")]}))

      assert [%{id: "global"}] = Provider.load_models(CustomProvider)
    end

    test "call-site source beats global config" do
      Application.put_env(:omni, :models, source: stub({:ok, [marker("global")]}))

      assert [%{id: "call-site"}] =
               Provider.load_models(CustomProvider, source: stub({:ok, [marker("call-site")]}))
    end

    test "per-module config beats the call-site source" do
      Application.put_env(:omni, CustomProvider, source: stub({:ok, [marker("per-module")]}))

      assert [%{id: "per-module"}] =
               Provider.load_models(CustomProvider, source: stub({:ok, [marker("call-site")]}))
    end

    test "the default source can also be configured explicitly by module" do
      Application.put_env(:omni, :models, source: Omni.Sources.ModelsDev)

      assert [%Omni.Model{} | _] = Provider.load_models(Omni.Providers.Anthropic)
    end

    test "a bare source module resolves with empty opts" do
      Application.put_env(:omni, :models, source: StubSource)

      assert Provider.load_models(CustomProvider) == []
    end
  end

  describe "source opts" do
    test "source opts merge with call-site opts, call-site winning" do
      source = {StubSource, notify: self(), tier: :source, keep: :source}

      Provider.load_models(CustomProvider, source: source, tier: :call_site, provider_id: :acme)

      assert_received {:fetch, CustomProvider, opts}
      assert opts[:tier] == :call_site
      assert opts[:keep] == :source
      assert opts[:provider_id] == :acme
      refute Keyword.has_key?(opts, :source)
    end
  end

  describe "load/1 as a cache pass" do
    setup do
      on_exit(fn ->
        :persistent_term.erase({Omni, :memo_a})
        :persistent_term.erase({Omni, :memo_b})
      end)
    end

    test "memo'd source work is shared within a pass and released between passes" do
      Application.put_env(:omni, :models, source: {MemoSource, notify: self()})

      Provider.load(memo_a: LoadingProviderA, memo_b: LoadingProviderB)
      assert_received {:memo_value, first_a}
      assert_received {:memo_value, first_b}
      assert first_a == first_b

      Provider.load(memo_a: LoadingProviderA)
      assert_received {:memo_value, second_a}
      refute second_a == first_a
    end
  end

  describe "failure policy" do
    test "custom module without provider_id warns and returns no models" do
      log =
        capture_log(fn ->
          assert Provider.load_models(CustomProvider) == []
        end)

      assert log =~ ":unknown_provider"
      assert log =~ "CustomProvider"
      assert log =~ "provider_id"
    end

    test "a source error logs the source, reason, and provider_id tried" do
      Application.put_env(:omni, :models, source: stub({:error, :boom}))

      log =
        capture_log(fn ->
          assert Provider.load_models(CustomProvider, provider_id: :acme) == []
        end)

      assert log =~ ":boom"
      assert log =~ "StubSource"
      assert log =~ ":acme"
    end

    test "a module that is not a source raises at resolution" do
      Application.put_env(:omni, :models, source: String)

      assert_raise ArgumentError, ~r/not an Omni\.Source/, fn ->
        Provider.load_models(CustomProvider)
      end
    end

    if Code.ensure_loaded?(LLMDB) do
      test "the LLMDB source resolves and loads models" do
        Application.put_env(:omni, :models, source: Omni.Sources.LLMDB)

        models = Provider.load_models(Omni.Providers.Anthropic)

        assert [%Omni.Model{} | _] = models
        assert Enum.all?(models, &(&1.provider == Omni.Providers.Anthropic))
      end
    else
      # only exercisable when the optional llm_db package is compiled out
      # (the OMNI_SKIP_LLMDB CI job)
      test "the LLMDB source raises when the llm_db package is absent" do
        Application.put_env(:omni, :models, source: Omni.Sources.LLMDB)

        assert_raise RuntimeError, ~r/llm_db package is not available/, fn ->
          Provider.load_models(Omni.Providers.Anthropic)
        end
      end
    end

    test "an unrecognized source value raises" do
      Application.put_env(:omni, :models, source: "models_dev")

      assert_raise ArgumentError, ~r/invalid model source/, fn ->
        Provider.load_models(CustomProvider)
      end
    end
  end
end
