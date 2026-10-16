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
               reasoning: false
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
               reasoning: false,
               input_modalities: [:text],
               output_modalities: [:text],
               release_date: nil
             } = model
    end

    test "parses full and year-month release dates" do
      full = Source.build_model(%{"id" => "a", "release_date" => "2025-08-05"})
      month = Source.build_model(%{"id" => "b", "release_date" => "2025-08"})

      assert full.release_date == ~D[2025-08-05]
      assert month.release_date == ~D[2025-08-01]
    end

    test "resolves the dialect string to the text dialect" do
      models =
        @multi_dialect_fixture_file
        |> fixture_entries()
        |> Map.new(&{&1["id"], Source.build_model(&1)})

      assert models["claude-test"].dialects == %{text: Omni.Dialects.AnthropicMessages}
      assert models["gpt-test"].dialects == %{text: Omni.Dialects.OpenAIResponses}
      assert models["gemini-test"].dialects == %{text: Omni.Dialects.GoogleGemini}
    end

    test "raises on unknown dialect string" do
      assert_raise ArgumentError, ~r/unknown_dialect/, fn ->
        Source.build_model(%{"id" => "bad", "dialect" => "bogus_format"})
      end
    end
  end
end
