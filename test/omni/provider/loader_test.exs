defmodule Omni.Provider.LoaderTest do
  # async: false — some tests set global :omni env (:models, :providers).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Omni.{Model, Provider}
  alias Omni.Provider.{Endpoint, Loader}
  alias Omni.Test.{Fixtures, StubSource}

  @completions Omni.Dialects.OpenAICompletions
  @responses Omni.Dialects.OpenAIResponses
  @messages Omni.Dialects.AnthropicMessages

  defmodule ConfigModule do
    @behaviour Omni.Provider

    @impl true
    def config do
      [
        name: "From Module",
        headers: %{"x-module" => "1"},
        dialects: %{Omni.Dialects.OpenAICompletions => [base_url: "https://module.test/v1"]}
      ]
    end

    @impl true
    def models(models, provider) do
      send(self(), {:models_called, provider})
      models
    end
  end

  defmodule CompatModule do
    @behaviour Omni.Provider

    @impl true
    def config do
      [
        dialects: %{
          Omni.Dialects.OpenAICompletions => [
            compat: [max_tokens_field: "max_tokens", omit: [:cache]]
          ]
        }
      ]
    end
  end

  defmodule RestampModule do
    @behaviour Omni.Provider

    @impl true
    def models(models, _provider),
      do: Enum.map(models, &%{&1 | dialects: %{text: Omni.Dialects.AnthropicMessages}})
  end

  defmodule StampModule do
    @behaviour Omni.Provider

    @impl true
    def models(models, _provider) do
      Enum.map(models, fn
        %{dialects: dialects} = model when dialects == %{} ->
          %{model | dialects: %{text: Omni.Dialects.OpenAICompletions}}

        model ->
          model
      end)
    end
  end

  defmodule BaseUrlModule do
    @behaviour Omni.Provider

    @impl true
    def config, do: [base_url: "https://module.test/v1"]
  end

  defmodule MemoSource do
    @behaviour Omni.Source

    @impl true
    def fetch(id, opts) do
      value = Omni.Source.memo({__MODULE__, :value}, fn -> :erlang.unique_integer() end)
      send(opts[:notify], {:memo_value, value})
      {:ok, %Provider{id: id}, []}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:omni, :models)
      Application.delete_env(:omni, :providers)
    end)
  end

  defp model(id, dialect \\ nil) do
    dialects = if dialect, do: %{text: dialect}, else: %{}
    Model.new(id: id, name: id, dialects: dialects)
  end

  @catalog_url "https://catalog.test/v1"

  defp catalog(provider_attrs, models) do
    provider =
      struct!(
        %Provider{
          id: :cat,
          name: "Catalog",
          api_key: {:system, "CAT_KEY"},
          dialects: %{@completions => %Endpoint{base_url: @catalog_url}}
        },
        provider_attrs
      )

    {StubSource, return: {:ok, provider, models}}
  end

  defp assemble(opts, id \\ :cat), do: Loader.assemble(id, opts)

  defp url(provider, dialect), do: provider.dialects[dialect].base_url

  describe "layering" do
    test "uses source values when nothing overrides them" do
      {provider, [model]} = assemble(source: catalog([], [model("m", @completions)]))

      assert provider.name == "Catalog"
      assert url(provider, @completions) == @catalog_url
      assert provider.api_key == {:system, "CAT_KEY"}
      assert provider.auth == :dialect
      assert model.provider == provider
    end

    test "module config overrides the source; app config overrides the module" do
      Application.put_env(:omni, :providers,
        cat: [dialects: %{@completions => [base_url: "https://app.test/v1"]}]
      )

      {provider, _} = assemble(source: catalog([], []), module: ConfigModule)

      assert provider.name == "From Module"
      assert url(provider, @completions) == "https://app.test/v1"
      assert provider.module == ConfigModule
    end

    test "inline opts override app config" do
      Application.put_env(:omni, :providers, cat: [name: "App"])

      {provider, _} = assemble(source: catalog([], []), name: "Inline")

      assert provider.name == "Inline"
    end

    test "headers merge by key across layers" do
      Application.put_env(:omni, :providers, cat: [headers: %{"x-app" => "1"}])

      {provider, _} =
        assemble(
          source: catalog([headers: %{"x-source" => "1"}], []),
          module: ConfigModule,
          headers: [{"x-inline", "1"}]
        )

      assert provider.headers == %{
               "x-source" => "1",
               "x-module" => "1",
               "x-app" => "1",
               "x-inline" => "1"
             }
    end

    test "models/2 receives the merged provider" do
      assemble(source: catalog([], [model("m", @completions)]), module: ConfigModule)

      assert_received {:models_called, provider}
      assert url(provider, @completions) == "https://module.test/v1"
    end
  end

  describe "endpoints" do
    test "a layer adds an endpoint for another dialect" do
      {provider, _} =
        assemble(
          source: catalog([], []),
          dialects: %{@messages => [base_url: "https://catalog.test/anthropic/v1"]}
        )

      assert url(provider, @completions) == @catalog_url
      assert url(provider, @messages) == "https://catalog.test/anthropic/v1"
    end

    test "[] declares a dialect with no URL" do
      {provider, _} = assemble(source: catalog([], []), dialects: %{@messages => []})

      assert provider.dialects[@messages] == %Endpoint{base_url: nil, compat: %{}}
    end

    test "a layer setting only compat keeps the URL below it" do
      {provider, _} =
        assemble(
          source: catalog([], []),
          dialects: %{@completions => [compat: [max_tokens_field: "max_tokens"]]}
        )

      assert provider.dialects[@completions] == %Endpoint{
               base_url: @catalog_url,
               compat: %{max_tokens_field: "max_tokens"}
             }
    end

    test "an unknown endpoint key raises" do
      assert_raise ArgumentError, ~r/unknown key :path_prefix/, fn ->
        assemble(source: catalog([], []), dialects: %{@completions => [path_prefix: "/v1"]})
      end
    end
  end

  describe "host" do
    test "moves every endpoint URL from the source and module, keeping paths" do
      source =
        catalog(
          [
            dialects: %{
              @completions => %Endpoint{base_url: "https://catalog.test/v1"},
              @messages => %Endpoint{base_url: "https://other.test/anthropic/v1"}
            }
          ],
          []
        )

      {provider, _} = assemble(source: source, host: "http://localhost:4000")

      assert url(provider, @completions) == "http://localhost:4000/v1"
      assert url(provider, @messages) == "http://localhost:4000/anthropic/v1"
    end

    test "fills a templated origin" do
      source =
        catalog([dialects: %{@completions => %Endpoint{base_url: "${GW_BASE_URL}/v1"}}], [])

      {provider, _} = assemble(source: source, host: "https://gw.example.com")

      assert url(provider, @completions) == "https://gw.example.com/v1"
    end

    test "leaves URLs written in app config as written" do
      {provider, _} =
        assemble(
          source: catalog([], []),
          host: "http://localhost:4000",
          dialects: %{@messages => [base_url: "https://pinned.test/v1"]}
        )

      assert url(provider, @completions) == "http://localhost:4000/v1"
      assert url(provider, @messages) == "https://pinned.test/v1"
    end

    test "a host with a path raises, pointing to endpoint URLs" do
      assert_raise ArgumentError, ~r/host: takes an origin.*dialects:/s, fn ->
        assemble(source: catalog([], []), host: "http://localhost:4000/v1")
      end
    end

    test "is not stored on the provider" do
      {provider, _} = assemble(source: catalog([], []), host: "http://localhost:4000")

      refute Map.has_key?(Map.from_struct(provider), :host)
    end
  end

  describe "compat" do
    test "flags are set under their dialect" do
      {provider, [model]} =
        assemble(
          source: catalog([], [model("m", @completions)]),
          dialects: %{@completions => [compat: [max_tokens_field: "max_tokens"]]}
        )

      assert provider.dialects[@completions].compat == %{max_tokens_field: "max_tokens"}
      assert Omni.Dialect.compat(model, @completions) == %{max_tokens_field: "max_tokens"}
    end

    test "like: copies a built-in's flags for the dialect, with the layer's own over them" do
      {provider, _} =
        assemble(
          source: catalog([], [model("m", @completions)]),
          dialects: %{@completions => [compat: [like: :zai, attachment_format: :file]]}
        )

      assert provider.dialects[@completions].compat == %{
               max_tokens_field: "max_tokens",
               thinking_toggle_format: :thinking_type,
               thinking_replay_format: :reasoning_content,
               output_format: :json_object,
               attachment_format: :file
             }
    end

    test "like: raises when the built-in sets no endpoint for the dialect" do
      assert_raise ArgumentError, ~r/sets no endpoint for/, fn ->
        assemble(source: catalog([], []), dialects: %{@messages => [compat: [like: :zai]]})
      end
    end

    test "app config flags merge one at a time over a module's" do
      Application.put_env(:omni, :providers,
        cat: [dialects: %{@completions => [compat: [max_tokens_field: "max_tokens_v2"]]}]
      )

      {provider, _} =
        assemble(source: catalog([], [model("m", @completions)]), module: CompatModule)

      assert provider.dialects[@completions].compat == %{
               max_tokens_field: "max_tokens_v2",
               omit: [:cache]
             }
    end

    test "unknown flags raise" do
      assert_raise ArgumentError, ~r/unknown compat flags \[:max_token_field\]/, fn ->
        assemble(
          source: catalog([], []),
          dialects: %{@completions => [compat: [max_token_field: "x"]]}
        )
      end
    end

    test "invalid flag values raise" do
      assert_raise ArgumentError, ~r/invalid compat flags/, fn ->
        assemble(
          source: catalog([], []),
          dialects: %{@completions => [compat: [output_format: :yaml]]}
        )
      end
    end

    test "like: must name a built-in" do
      assert_raise ArgumentError, ~r/is not a built-in provider/, fn ->
        assemble(source: catalog([], []), dialects: %{@completions => [compat: [like: :nope]]})
      end
    end

    test "every built-in's compat validates" do
      for id <- Provider.builtins() do
        {provider, _models} = Loader.assemble(id)

        for {dialect, %Endpoint{compat: flags}} <- provider.dialects do
          assert is_atom(dialect) and is_map(flags)
        end
      end
    end
  end

  describe "models" do
    test "a config entry merges over the source model with its id" do
      source = catalog([], [model("a", @completions), model("b", @completions)])

      {_provider, models} =
        assemble(source: source, models: [[id: "b", name: "Renamed", context_size: 1000]])

      b = Enum.find(models, &(&1.id == "b"))
      assert b.name == "Renamed"
      assert b.context_size == 1000
      assert b.dialects == %{text: @completions}
      assert Enum.map(models, & &1.id) == ["a", "b"]
    end

    test "dialects in a config entry merge by capability" do
      endpoints = %{
        @completions => %Endpoint{base_url: @catalog_url},
        @responses => %Endpoint{base_url: @catalog_url}
      }

      source = catalog([dialects: endpoints], [model("m", @responses)])

      {_provider, [model]} =
        assemble(source: source, models: [[id: "m", dialects: %{text: @completions}]])

      assert model.dialects == %{text: @completions}
    end

    test "a config entry with a new id is added" do
      {_provider, models} =
        assemble(
          source: catalog([], [model("a", @completions)]),
          models: [[id: "c", dialects: %{text: @completions}]]
        )

      assert Enum.map(models, & &1.id) == ["a", "c"]
    end

    test "entries for the same id in app config and inline opts merge" do
      Application.put_env(:omni, :providers,
        cat: [models: [[id: "c", dialects: %{text: @completions}, context_size: 10]]]
      )

      {_provider, [model]} = assemble(source: catalog([], []), models: [[id: "c", name: "C"]])

      assert {model.name, model.context_size} == {"C", 10}
    end

    test "a config model with no dialect raises" do
      assert_raise ArgumentError, ~r/model "c" in config.*has no dialect/s, fn ->
        assemble(source: catalog([], []), models: ["c"])
      end
    end

    test "a module's models/2 can stamp config models before the check" do
      {_provider, [model]} =
        assemble(source: catalog([], []), module: StampModule, models: ["c"])

      assert model.dialects == %{text: @completions}
    end

    test "a config model whose dialect has no endpoint raises" do
      assert_raise ArgumentError, ~r/no endpoint for/, fn ->
        assemble(source: catalog([], []), models: [[id: "c", dialects: %{text: @messages}]])
      end
    end

    test "a catalog model with no dialect is skipped with a warning, never filled" do
      log =
        capture_log(fn ->
          {_provider, models} =
            assemble(source: catalog([], [model("a", @completions), model("b")]))

          assert Enum.map(models, & &1.id) == ["a"]
        end)

      assert log =~ "skipped 1 models with no dialect: b"
    end

    test "a catalog model whose dialect has no endpoint is skipped with a warning" do
      log =
        capture_log(fn ->
          {_provider, models} =
            assemble(source: catalog([], [model("a", @completions), model("b", @messages)]))

          assert Enum.map(models, & &1.id) == ["a"]
        end)

      assert log =~ "skipped 1 models with a dialect it has no endpoint for: b"
    end

    test "a module's models/2 can re-stamp models" do
      {_provider, [model]} =
        assemble(
          source: catalog([], [model("m", @completions)]),
          module: RestampModule,
          dialects: %{@messages => [base_url: "https://x.test/v1"]}
        )

      assert model.dialects == %{text: @messages}
    end

    test "put_model/1 raises for a model with no dialects" do
      provider = Fixtures.provider()
      model = Model.new(id: "x", name: "x", provider: provider)

      assert_raise ArgumentError, ~r/has no dialects/, fn -> Loader.put_model(model) end
    end
  end

  describe "validation" do
    test "an unknown id loads with no endpoints; a missing URL is a request-time error" do
      log =
        capture_log(fn ->
          assert {%Provider{dialects: dialects}, []} =
                   assemble([source: StubSource], :not_in_catalog)

          assert dialects == %{}
        end)

      assert log =~ "loaded no models"
    end

    test "an invalid dialect module raises" do
      assert_raise ArgumentError, ~r/is not an Omni.Dialect module/, fn ->
        assemble(source: catalog([], []), dialects: %{String => []})
      end
    end

    test "an invalid auth value raises" do
      assert_raise ArgumentError, ~r/invalid auth/, fn ->
        assemble(source: catalog([], []), auth: :magic)
      end
    end

    test "an unknown config key raises" do
      assert_raise ArgumentError, ~r/unknown key :bogus/, fn ->
        assemble(source: catalog([], []), bogus: true)
      end
    end

    test "auth_header raises with a migration hint" do
      assert_raise ArgumentError, ~r/use auth: \{:header, "x-api-key"\}/, fn ->
        assemble(source: catalog([], []), auth_header: "x-api-key")
      end
    end

    test "an unavailable module raises" do
      assert_raise ArgumentError, ~r/is not available/, fn ->
        assemble(source: catalog([], []), module: Omni.NoSuchModule)
      end
    end

    test "an invalid model entry raises" do
      assert_raise ArgumentError, ~r/has no :id/, fn ->
        assemble(source: catalog([], []), models: [[name: "No Id"]])
      end
    end
  end

  describe "migration" do
    test "provider base_url: that only moves the origin suggests host:" do
      assert_raise ArgumentError, ~r/cat: \[host: "http:\/\/localhost:4000"\]/, fn ->
        assemble(source: catalog([], []), base_url: "http://localhost:4000/v1")
      end
    end

    test "provider base_url: with another path suggests the endpoint URL" do
      message =
        ~r/cat: \[dialects: %\{Omni.Dialects.OpenAICompletions => \[base_url: "https:\/\/x.test\/api"\]\}\]/

      assert_raise ArgumentError, message, fn ->
        assemble(source: catalog([], []), base_url: "https://x.test/api")
      end
    end

    test "provider base_url: with no endpoints suggests the dialects: form" do
      assert_raise ArgumentError, ~r/dialects: %\{Omni.Dialects.OpenAICompletions/, fn ->
        assemble([source: StubSource, base_url: "http://gpu:8000/v1"], :gpu_box)
      end
    end

    test "base_url: in a module's config/0 raises" do
      assert_raise ArgumentError, ~r/base_url: moved to each dialect's endpoint/, fn ->
        assemble(source: catalog([], []), module: BaseUrlModule)
      end
    end

    test "top-level compat: raises, pointing under the dialect" do
      assert_raise ArgumentError, ~r/compat: moved under its dialect/, fn ->
        assemble(source: catalog([], []), compat: [like: :zai])
      end
    end

    test "capability-keyed dialects: raises" do
      assert_raise ArgumentError, ~r/dialects: is now keyed by dialect module/, fn ->
        assemble(source: catalog([], []), dialects: %{text: @completions})
      end
    end
  end

  describe "defaults" do
    test "an id the catalog doesn't know is named after its id" do
      {provider, _} =
        assemble(
          [source: StubSource, dialects: %{@completions => [base_url: "https://x.test/v1"]}],
          :not_in_catalog
        )

      assert provider.name == "not_in_catalog"
    end

    test "a built-in id gets its module" do
      {provider, _} = assemble([source: catalog([], [])], :groq)

      assert provider.module == Omni.Providers.Groq
    end
  end

  describe "filter" do
    test "applies to every model, including config models" do
      Application.put_env(:omni, :models, filter: &String.starts_with?(&1.id, "keep"))

      {_provider, models} =
        assemble(
          source: catalog([], [model("keep-a", @completions), model("drop-b", @completions)]),
          models: [
            [id: "keep-c", dialects: %{text: @completions}],
            [id: "drop-d", dialects: %{text: @completions}]
          ]
        )

      assert Enum.map(models, & &1.id) == ["keep-a", "keep-c"]
    end

    test "accepts a {module, function} tuple" do
      Application.put_env(:omni, :models, filter: {__MODULE__, :reasoning?})

      {_provider, models} =
        assemble(
          source: catalog([], []),
          models: [
            [id: "r", thinking: true, dialects: %{text: @completions}],
            [id: "plain", dialects: %{text: @completions}]
          ]
        )

      assert Enum.map(models, & &1.id) == ["r"]
    end
  end

  def reasoning?(model), do: model.thinking != false

  describe "sources" do
    test "defaults to the ModelsDev source" do
      {provider, models} = Loader.assemble(:anthropic)

      assert provider.name == "Anthropic"
      assert models != []
    end

    test "a provider's own source wins over the global source" do
      Application.put_env(:omni, :models, source: {StubSource, notify: self(), tag: :global})

      assemble(
        source: {StubSource, notify: self(), tag: :own, return: elem(catalog([], []), 1)[:return]}
      )

      assert_received {:fetch, :cat, opts}
      assert opts[:tag] == :own
    end

    test "the global source is used otherwise" do
      Application.put_env(:omni, :models,
        source: {StubSource, notify: self(), return: elem(catalog([], []), 1)[:return]}
      )

      Loader.assemble(:cat)

      assert_received {:fetch, :cat, _opts}
    end

    test "a source error is logged and the provider loads from config alone" do
      log =
        capture_log(fn ->
          {provider, []} =
            assemble(
              source: {StubSource, return: {:error, :boom}},
              dialects: %{@completions => [base_url: "https://x.test/v1"]}
            )

          assert url(provider, @completions) == "https://x.test/v1"
        end)

      assert log =~ ":boom"
      assert log =~ "StubSource"
    end

    test "a module that is not a source raises" do
      assert_raise ArgumentError, ~r/not an Omni\.Source/, fn -> assemble(source: String) end
    end

    test "an unrecognized source value raises" do
      assert_raise ArgumentError, ~r/invalid model source/, fn ->
        assemble(source: "models_dev")
      end
    end

    test "memo'd source work is shared within a load pass and released between passes" do
      a = :"memo_a_#{System.unique_integer([:positive])}"
      b = :"memo_b_#{System.unique_integer([:positive])}"
      on_exit(fn -> Enum.each([a, b], &Fixtures.unload/1) end)

      Application.put_env(:omni, :models, source: {MemoSource, notify: self()})

      capture_log(fn -> Loader.load([a, b]) end)
      assert_received {:memo_value, first_a}
      assert_received {:memo_value, first_b}
      assert first_a == first_b

      capture_log(fn -> Loader.load([a]) end)
      assert_received {:memo_value, second_a}
      refute second_a == first_a
    end

    if Code.ensure_loaded?(LLMDB) do
      test "the LLMDB source loads a built-in" do
        {provider, models} = Loader.assemble(:anthropic, source: Omni.Sources.LLMDB)

        assert [%Model{} | _] = models
        assert Map.keys(provider.dialects) == [@messages]
        assert url(provider, @messages) == "https://api.anthropic.com/v1"
      end
    else
      # only exercisable when the optional llm_db package is compiled out
      # (the OMNI_SKIP_LLMDB CI job)
      test "the LLMDB source raises when the llm_db package is absent" do
        assert_raise RuntimeError, ~r/llm_db package is not available/, fn ->
          Loader.assemble(:anthropic, source: Omni.Sources.LLMDB)
        end
      end
    end
  end

  describe "boot config validation" do
    test "a module in providers: raises, suggesting the id" do
      Application.put_env(:omni, :models, providers: [Omni.Providers.OpenAI])

      assert_raise ArgumentError, ~r/takes provider ids.*:openai/s, fn -> Loader.boot() end
    end

    test "an unknown :models key raises" do
      Application.put_env(:omni, :models, providers: [], bogus: 1)

      assert_raise ArgumentError, ~r/unknown key :bogus/, fn -> Loader.boot() end
    end

    test "an invalid filter raises" do
      Application.put_env(:omni, :models, providers: [], filter: "nope")

      assert_raise ArgumentError, ~r/invalid filter/, fn -> Loader.boot() end
    end

    test "provider config is validated even for providers that aren't loaded" do
      Application.put_env(:omni, :models, providers: [])
      Application.put_env(:omni, :providers, never_loaded: [auth_header: "x-api-key"])

      assert_raise ArgumentError, ~r/auth_header: was replaced by auth:/, fn -> Loader.boot() end
    end

    test "an empty providers list loads nothing" do
      Application.put_env(:omni, :models, providers: [])

      assert :ok = Loader.boot()
    end
  end
end
