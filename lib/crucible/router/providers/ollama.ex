defmodule Crucible.Router.Providers.Ollama do
  @moduledoc "Local Ollama via OpenAI-compatible endpoint (default 127.0.0.1:11434)."

  @behaviour Crucible.Router.Provider

  alias Crucible.Router.Providers.OpenAICompat

  @default_base_url "http://localhost:11434/v1"

  @impl true
  def name, do: "ollama"

  @impl true
  def request(model_id, request) do
    local_model = if model_id == "local-ollama", do: "llama3.2", else: model_id

    OpenAICompat.request(local_model, request,
      provider_name: "ollama",
      base_url: base_url(),
      api_key: ""
    )
  end

  @impl true
  def health_check do
    case Req.get(base_url() <> "/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  end

  defp base_url,
    do:
      System.get_env("OLLAMA_BASE_URL") ||
        Application.get_env(:crucible, :ollama_base_url, @default_base_url)
end
