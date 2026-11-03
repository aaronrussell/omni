defmodule Omni.Provider.EndpointTest do
  use ExUnit.Case, async: true

  alias Omni.Provider.Endpoint

  describe "validate_host/1" do
    test "accepts an origin, with or without a port" do
      assert :ok = Endpoint.validate_host("https://api.example.com")
      assert :ok = Endpoint.validate_host("http://gpu-box:11434")
      assert :ok = Endpoint.validate_host("http://localhost:4000/")
    end

    test "rejects a path, a query, a missing scheme, or a non-string" do
      for host <- ["http://localhost:4000/v1", "https://x.test?a=1", "gpu-box:11434", nil] do
        assert {:error, {:invalid_host, ^host}} = Endpoint.validate_host(host)
      end
    end
  end

  describe "put_host/2" do
    test "replaces the origin and keeps the path" do
      assert Endpoint.put_host("https://api.openai.com/v1", "http://localhost:4000") ==
               "http://localhost:4000/v1"

      assert Endpoint.put_host("http://localhost:11434", "http://gpu:11434/") ==
               "http://gpu:11434"
    end

    test "fills a templated host" do
      assert Endpoint.put_host("https://${HOST}/ai-gateway/v1", "https://db.example.com") ==
               "https://db.example.com/ai-gateway/v1"

      assert Endpoint.put_host("https://{WorkspaceId}.maas.aliyuncs.com/v1", "https://ws.test") ==
               "https://ws.test/v1"
    end

    test "fills a templated origin with no scheme" do
      assert Endpoint.put_host("${NEON_AI_GATEWAY_BASE_URL}/openai/v1", "https://br.neon.tech") ==
               "https://br.neon.tech/openai/v1"
    end

    test "leaves a missing URL missing" do
      assert Endpoint.put_host(nil, "http://localhost:4000") == nil
    end
  end

  describe "placeholder?/1" do
    test "spots either template form" do
      assert Endpoint.placeholder?("https://${HOST}/v1")
      assert Endpoint.placeholder?("https://{region}.example.com/v1")
      refute Endpoint.placeholder?("https://api.example.com/v1")
    end
  end
end
