defmodule Crucible.Router.Providers.MiniMax do
  @moduledoc "MiniMax M-series via OpenAI-compatible endpoint."

  @behaviour Crucible.Router.Provider

  alias Crucible.Router.Providers.OpenAICompat

  @default_base_url "https://api.minimax.io/v1"

  @impl true
  def name, do: "minimax"

  @impl true
  def request(model_id, request) do
    OpenAICompat.request(model_id, request,
      provider_name: "minimax",
      base_url: base_url(),
      api_key: api_key()
    )
  end

  @impl true
  def health_check,
    do: match?({:ok, _}, request("MiniMax-M2", %{prompt: "ping", max_tokens: 1}))

  defp api_key,
    do: System.get_env("MINIMAX_API_KEY") || Application.get_env(:crucible, :minimax_api_key, "")

  defp base_url,
    do: System.get_env("MINIMAX_BASE_URL") || Application.get_env(:crucible, :minimax_base_url, @default_base_url)
end
