defmodule Omni.Provider.LoaderTest do
  # async: false — some tests set global :omni env (:models, :providers).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Omni.{Model, Provider}
  alias Omni.Provider.Loader
  alias Omni.Test.{Fixtures, StubSource}

  @completions Omni.Dialects.OpenAICompletions
  @responses Omni.Dialects.OpenAIResponses
  @messages Omni.Dialects.AnthropicMessages

  defmodule ConfigModule do
    @behaviour Omni.Provider

    @impl true
    def config do
      [name: "From Module", base_url: "https://module.test/v1", headers: %{"x-module" => "1"}]
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
        compat: %{
          Omni.Dialects.OpenAICompletions => [
            max_tokens_field: "max_tokens",
            omit: [:cache]
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

  defmodule MemoSource do
    @behaviour Omni.Source

    @impl true
    def fetch(id, opts) do
      value = Omni.Source.memo({__MODULE__, :value}, fn -> :erlang.unique_integer() end)
      send(opts[:notify], {:memo_value, value})
      {:ok, %Provider{id: id, base_url: "https://memo.test/v1"}, []}
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

  defp catalog(provider_attrs, models) do
    provider =
      struct!(
        %Provider{
          id: :cat,
          name: "Catalog",
          base_url: "https://catalog.test/v1",
          api_key: {:system, "CAT_KEY"},
          dialects: %{text: [@completions]}
        },
        provider_attrs
      )

    {StubSource, return: {:ok, provider, models}}
  end

  defp assemble(opts, id \\ :cat), do: Loader.assemble(id, opts)

  describe "layering" do
    test "uses source values when nothing overrides them" do
      {provider, [model]} = assemble(source: catalog([], [model("m", @completions)]))

      assert provider.name == "Catalog"
      assert provider.base_url == "https://catalog.test/v1"
      assert provider.api_key == {:system, "CAT_KEY"}
      assert provider.auth == :dialect
      assert provider.tier == :catalog
      assert model.provider == provider
    end

    test "module config overrides the source; app config overrides the module" do
      Application.put_env(:omni, :providers, cat: [base_url: "https://app.test/v1"])

      {provider, _} = assemble(source: catalog([], []), module: ConfigModule)

      assert provider.name == "From Module"
      assert provider.base_url == "https://app.test/v1"
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

    test "config models merge with source models by id" do
      source = catalog([], [model("a", @completions), model("b", @completions)])

      {_provider, models} =
        assemble(source: source, models: [[id: "b", name: "Replaced"], "c"])

      assert Enum.map(models, &{&1.id, &1.name}) == [{"a", "a"}, {"b", "Replaced"}, {"c", "c"}]
    end

    test "models/2 receives the merged provider" do
      assemble(source: catalog([], [model("m", @completions)]), module: ConfigModule)

      assert_received {:models_called, %Provider{base_url: "https://module.test/v1"}}
    end
  end

  describe "compat" do
    test "flat flags apply to the provider's single dialect" do
      {provider, [model]} =
        assemble(
          source: catalog([], [model("m", @completions)]),
          compat: [max_tokens_field: "max_tokens"]
        )

      assert provider.compat == %{@completions => %{max_tokens_field: "max_tokens"}}
      assert model.provider.compat == provider.compat
    end

    test "flags keyed by dialect are kept as given" do
      {provider, _} =
        assemble(
          source: catalog([], [model("a", @completions), model("b", @messages)]),
          compat: %{@completions => [max_tokens_field: "max_tokens"], @messages => %{}}
        )

      assert provider.compat == %{
               @completions => %{max_tokens_field: "max_tokens"},
               @messages => %{}
             }
    end

    test "like: copies a built-in's flags, with the layer's own over them" do
      {provider, _} =
        assemble(
          source: catalog([], [model("m", @completions)]),
          compat: [like: :zai, attachment_format: :file]
        )

      assert provider.compat == %{
               @completions => %{
                 max_tokens_field: "max_tokens",
                 thinking_toggle_format: :thinking_type,
                 output_format: :json_object,
                 attachment_format: :file
               }
             }
    end

    test "app config flags merge one at a time over a module's" do
      Application.put_env(:omni, :providers, cat: [compat: [max_tokens_field: "max_tokens_v2"]])

      {provider, _} =
        assemble(source: catalog([], [model("m", @completions)]), module: CompatModule)

      assert provider.compat == %{
               @completions => %{max_tokens_field: "max_tokens_v2", omit: [:cache]}
             }
    end

    test "inline flags layer over app config" do
      Application.put_env(:omni, :providers, cat: [compat: [omit: [:cache]]])

      {provider, _} =
        assemble(source: catalog([], [model("m", @completions)]), compat: [omit: [:thinking]])

      assert provider.compat == %{@completions => %{omit: [:thinking]}}
    end

    test "flat flags on a multi-dialect provider raise, naming the fix" do
      source = catalog([], [model("a", @completions), model("b", @messages)])

      assert_raise ArgumentError, ~r/must be keyed by dialect/, fn ->
        assemble(source: source, compat: [max_tokens_field: "max_tokens"])
      end
    end

    test "like: alone is fine on a multi-dialect provider" do
      source = catalog([], [model("a", @completions), model("b", @messages)])

      {provider, _} = assemble(source: source, compat: [like: :moonshotai])

      assert provider.compat == %{@completions => %{thinking_toggle_format: :thinking_type}}
    end

    test "unknown flags raise" do
      assert_raise ArgumentError, ~r/unknown compat flags \[:max_token_field\]/, fn ->
        assemble(source: catalog([], [model("m", @completions)]), compat: [max_token_field: "x"])
      end
    end

    test "invalid flag values raise" do
      assert_raise ArgumentError, ~r/invalid compat flags/, fn ->
        assemble(
          source: catalog([], [model("m", @completions)]),
          compat: [output_format: :yaml]
        )
      end
    end

    test "flags for a dialect the provider doesn't speak raise" do
      assert_raise ArgumentError, ~r/none of its models speak/, fn ->
        assemble(
          source: catalog([], [model("m", @completions)]),
          compat: %{@messages => []}
        )
      end
    end

    test "like: must name a built-in" do
      assert_raise ArgumentError, ~r/is not a built-in provider/, fn ->
        assemble(source: catalog([], [model("m", @completions)]), compat: [like: :nope])
      end
    end

    test "mixing flags and dialect keys raises" do
      assert_raise ArgumentError, ~r/mixes flags with dialect keys/, fn ->
        assemble(
          source: catalog([], [model("m", @completions)]),
          compat: %{@completions => [], :omit => [:cache]}
        )
      end
    end

    test "every built-in's compat is keyed by dialect and validates" do
      for id <- Provider.builtins() do
        {provider, _models} = Loader.assemble(id)

        for {dialect, flags} <- provider.compat do
          assert is_atom(dialect) and is_map(flags)
        end
      end
    end
  end

  describe "dialects" do
    test "a model without a dialect takes the provider's first" do
      {_provider, [model]} = assemble(source: catalog([], [model("m")]))

      assert model.dialects == %{text: @completions}
    end

    test "the provider's list is derived from its own plus its models'" do
      source = catalog([], [model("a", @completions), model("b", @messages)])

      {provider, _} = assemble(source: source)

      assert provider.dialects == %{text: [@completions, @messages]}
    end

    test "configured dialects fill gaps but never re-stamp a model" do
      source = catalog([], [model("has", @completions), model("lacks")])

      {provider, models} = assemble(source: source, dialects: %{text: @responses})

      by_id = Map.new(models, &{&1.id, &1.dialects.text})
      assert by_id == %{"has" => @completions, "lacks" => @responses}
      assert provider.dialects == %{text: [@responses, @completions]}
    end

    test "with no own list, a dialect every model shares fills the rest" do
      source = catalog([dialects: %{}], [model("a", @completions), model("b")])

      {_provider, models} = assemble(source: source)

      assert Enum.all?(models, &(&1.dialects == %{text: @completions}))
    end

    test "with no own list and mixed model dialects, dialect-less models are skipped" do
      source =
        catalog([dialects: %{}], [model("a", @completions), model("b", @messages), model("c")])

      log =
        capture_log(fn ->
          {_provider, models} = assemble(source: source)
          assert Enum.map(models, & &1.id) == ["a", "b"]
        end)

      assert log =~ "skipped 1 models with no dialect (c)"
    end

    test "a module's models/2 can re-stamp models" do
      {provider, [model]} =
        assemble(
          source: catalog([], [model("m", @completions)]),
          module: RestampModule,
          dialects: %{text: @messages}
        )

      assert model.dialects == %{text: @messages}
      assert provider.dialects == %{text: [@messages]}
    end
  end

  describe "validation" do
    test "an unknown id without a base_url raises, saying it isn't in the catalog" do
      assert_raise ArgumentError, ~r/no base_url — it is not in the catalog/, fn ->
        assemble([source: StubSource], :not_in_catalog)
      end
    end

    test "a catalog provider without a base URL raises, saying so" do
      assert_raise ArgumentError, ~r/the catalog has no base URL for it/, fn ->
        assemble(source: catalog([base_url: nil], []))
      end
    end

    test "models with no resolvable dialect raise" do
      assert_raise ArgumentError, ~r/no dialect for its models/, fn ->
        assemble(source: catalog([dialects: %{}], [model("a"), model("b")]))
      end
    end

    test "a provider with no models and no dialect only warns" do
      log =
        capture_log(fn ->
          assert {_provider, []} = assemble(source: catalog([dialects: %{}], []))
        end)

      assert log =~ "loaded no models"
    end

    test "an invalid dialect module raises" do
      assert_raise ArgumentError, ~r/is not an Omni.Dialect module/, fn ->
        assemble(source: catalog([], []), dialects: %{text: String})
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

  describe "tier" do
    test "is :custom for an id the catalog doesn't know" do
      {provider, _} =
        assemble(
          [source: StubSource, base_url: "https://x.test/v1", dialects: %{text: @completions}],
          :not_in_catalog
        )

      assert provider.tier == :custom
      assert provider.name == "not_in_catalog"
    end

    test "is :verified for a built-in id" do
      {provider, _} = assemble([source: catalog([], [])], :groq)

      assert provider.tier == :verified
      assert provider.module == Omni.Providers.Groq
    end
  end

  describe "filter" do
    test "applies to every model, including config models" do
      Application.put_env(:omni, :models, filter: &String.starts_with?(&1.id, "keep"))

      {_provider, models} =
        assemble(
          source: catalog([], [model("keep-a", @completions), model("drop-b")]),
          models: ["keep-c", "drop-d"]
        )

      assert Enum.map(models, & &1.id) == ["keep-a", "keep-c"]
    end

    test "accepts a {module, function} tuple" do
      Application.put_env(:omni, :models, filter: {__MODULE__, :reasoning?})

      {_provider, models} =
        assemble(source: catalog([], []), models: [[id: "r", thinking: true], "plain"])

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
              base_url: "https://x.test/v1",
              dialects: %{text: @completions}
            )

          assert provider.tier == :custom
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
        assert provider.dialects == %{text: [@messages]}
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
