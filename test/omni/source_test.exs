defmodule Omni.SourceTest do
  use ExUnit.Case, async: true

  alias Omni.Source

  describe "with_cache/1 and memo/2" do
    test "memo runs the function on every call outside a cache scope" do
      first = Source.memo(:key, fn -> :erlang.unique_integer() end)
      second = Source.memo(:key, fn -> :erlang.unique_integer() end)

      refute first == second
    end

    test "memo caches per key within a cache scope" do
      {a, b, c} =
        Source.with_cache(fn ->
          a = Source.memo(:key, fn -> :erlang.unique_integer() end)
          b = Source.memo(:key, fn -> :erlang.unique_integer() end)
          c = Source.memo(:other_key, fn -> :erlang.unique_integer() end)
          {a, b, c}
        end)

      assert a == b
      refute a == c
    end

    test "with_cache returns the function's result" do
      assert Source.with_cache(fn -> :result end) == :result
    end

    test "each cache scope is independent" do
      first = Source.with_cache(fn -> Source.memo(:key, fn -> :erlang.unique_integer() end) end)
      second = Source.with_cache(fn -> Source.memo(:key, fn -> :erlang.unique_integer() end) end)

      refute first == second
    end

    test "the scope is cleared when the function raises" do
      assert_raise RuntimeError, "boom", fn ->
        Source.with_cache(fn ->
          Source.memo(:key, fn -> :cached end)
          raise "boom"
        end)
      end

      # Outside any scope now — memo must recompute, not see :cached.
      assert Source.memo(:key, fn -> :recomputed end) == :recomputed
    end

    test "a nested with_cache reuses the enclosing scope" do
      Source.with_cache(fn ->
        outer = Source.memo(:key, fn -> :erlang.unique_integer() end)

        inner =
          Source.with_cache(fn -> Source.memo(:key, fn -> :erlang.unique_integer() end) end)

        assert inner == outer

        # The inner call's exit must not have torn the scope down.
        assert Source.memo(:key, fn -> :erlang.unique_integer() end) == outer
      end)
    end
  end

  describe "endpoints/3" do
    alias Omni.Provider.Endpoint

    @completions Omni.Dialects.OpenAICompletions
    @messages Omni.Dialects.AnthropicMessages

    defp m(id, dialect), do: Omni.Model.new(id: id, name: id, dialects: %{text: dialect})

    test "each dialect takes its first model's URL, else the provider URL" do
      pairs = [
        {m("b", @completions), nil},
        {m("a", @messages), "https://gw.test/anthropic/v1"}
      ]

      {endpoints, models, []} = Omni.Source.endpoints(pairs, "https://gw.test/v1", nil)

      assert endpoints == %{
               @completions => %Endpoint{base_url: "https://gw.test/v1"},
               @messages => %Endpoint{base_url: "https://gw.test/anthropic/v1"}
             }

      assert Enum.map(models, & &1.id) == ["a", "b"]
    end

    test "a later model of a dialect at another URL is skipped" do
      pairs = [{m("b", @completions), "https://two.test/v1"}, {m("a", @completions), nil}]

      {endpoints, models, [{skipped, url}]} =
        Omni.Source.endpoints(pairs, "https://one.test/v1", nil)

      assert endpoints == %{@completions => %Endpoint{base_url: "https://one.test/v1"}}
      assert Enum.map(models, & &1.id) == ["a"]
      assert {skipped.id, url} == {"b", "https://two.test/v1"}
    end

    test "the provider-level dialect gets the provider URL with no models" do
      assert {%{@completions => %Endpoint{base_url: "https://x.test/v1"}}, [], []} =
               Omni.Source.endpoints([], "https://x.test/v1", @completions)
    end

    test "a provider URL with no dialect is dropped" do
      assert {endpoints, [], []} = Omni.Source.endpoints([], "https://x.test/v1", nil)
      assert endpoints == %{}
    end
  end

  describe "build_model/1" do
    @fixture_file Path.expand("../support/fixtures/test_models.json", __DIR__)
    @multi_dialect_fixture_file Path.expand(
                                  "../support/fixtures/test_models_multi_dialect.json",
                                  __DIR__
                                )

    defp fixture_entries(file), do: file |> File.read!() |> JSON.decode!()

    test "maps all data fields to struct fields" do
      [small | _] = fixture_entries(@fixture_file)

      assert %Omni.Model{
               id: "test-model-small",
               name: "Test Model Small",
               context_size: 8192,
               max_output_tokens: 2048,
               input_cost: 0.5,
               output_cost: 1.5,
               cache_read_cost: 0.05,
               cache_write_cost: 0.5,
               thinking: false
             } = Source.build_model(small)
    end

    test "builds models without a provider" do
      for data <- fixture_entries(@fixture_file) do
        model = Source.build_model(data)
        assert model.provider == nil
        assert model.dialects == %{}
      end
    end

    test "converts modality strings to atoms and filters to supported" do
      data = @fixture_file |> fixture_entries() |> Enum.find(&(&1["id"] == "test-model-multi"))
      model = Source.build_model(data)

      assert model.input_modalities == [:text, :image]
      assert model.output_modalities == [:text]
    end

    test "defaults costs, limits, modalities, reasoning and name when absent" do
      model = Source.build_model(%{"id" => "bare"})

      assert %Omni.Model{
               name: "bare",
               input_cost: 0,
               output_cost: 0,
               cache_read_cost: 0,
               cache_write_cost: 0,
               context_size: 0,
               max_output_tokens: 0,
               thinking: false,
               input_modalities: [:text],
               output_modalities: [:text],
               release_date: nil
             } = model
    end

    test "builds thinking data from reasoning_options" do
      model =
        Source.build_model(%{
          "id" => "a",
          "reasoning" => true,
          "reasoning_options" => [
            %{"type" => "toggle"},
            %{"type" => "effort", "values" => ["none", "low", nil, "high"]},
            %{type: "budget_tokens", min: 1024},
            %{"type" => "unknown"}
          ]
        })

      assert model.thinking == %{
               efforts: ["none", "low", "high"],
               toggle: true,
               budget: {1024, nil}
             }
    end

    test "reasoning without options, or with an empty list, is true" do
      assert Source.build_model(%{"id" => "a", "reasoning" => true}).thinking == true

      assert Source.build_model(%{"id" => "b", "reasoning" => true, "reasoning_options" => []}).thinking ==
               true
    end

    test "options without reasoning are ignored" do
      data = %{"id" => "a", "reasoning" => false, "reasoning_options" => [%{"type" => "toggle"}]}
      assert Source.build_model(data).thinking == false
    end

    test "parses full and year-month release dates" do
      full = Source.build_model(%{"id" => "a", "release_date" => "2025-08-05"})
      month = Source.build_model(%{"id" => "b", "release_date" => "2025-08"})

      assert full.release_date == ~D[2025-08-05]
      assert month.release_date == ~D[2025-08-01]
    end

    test "resolves dialect strings under their capabilities" do
      models =
        @multi_dialect_fixture_file
        |> fixture_entries()
        |> Map.new(&{&1["id"], Source.build_model(&1)})

      assert models["claude-test"].dialects == %{text: Omni.Dialects.AnthropicMessages}
      assert models["gpt-test"].dialects == %{text: Omni.Dialects.OpenAIResponses}
      assert models["gemini-test"].dialects == %{text: Omni.Dialects.GoogleGenerateContent}

      assert Source.build_model(%{"id" => "d", "dialects" => ["systemone"]}).dialects ==
               %{decision: Omni.Dialects.SystemOne}

      both =
        Source.build_model(%{"id" => "b", "dialects" => ["openai_responses", "openai_decisions"]})

      assert both.dialects == %{
               text: Omni.Dialects.OpenAIResponses,
               decision: Omni.Dialects.OpenAIDecisions
             }
    end

    test "raises on unknown dialect string" do
      assert_raise ArgumentError, ~r/unknown_dialect/, fn ->
        Source.build_model(%{"id" => "bad", "dialects" => ["bogus_format"]})
      end
    end

    test "raises on two dialects for one capability" do
      assert_raise ArgumentError, ~r/both serve :text/, fn ->
        Source.build_model(%{
          "id" => "bad",
          "dialects" => ["openai_responses", "anthropic_messages"]
        })
      end
    end
  end
end
