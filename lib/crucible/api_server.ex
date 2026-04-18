defmodule Crucible.ApiServer do
  @moduledoc "HTTP client for the Node API server on port 4800 (inbox, plans, reports)."

  alias Crucible.ExternalCircuitBreaker

  @timeout 3_000

  defp base_url do
    Application.get_env(:crucible, :api_server_url,
      Application.get_env(:crucible, :ts_dashboard_url, "http://localhost:4800")
    )
  end

  @spec fetch(String.t()) :: term() | nil
  def fetch(path) do
    case ExternalCircuitBreaker.check(:api_server) do
      {:blocked, _} ->
        nil

      :ok ->
        case Req.get("#{base_url()}#{path}",
               receive_timeout: @timeout,
               retry: false,
               connect_options: [timeout: @timeout]
             ) do
          {:ok, %{status: 200, body: body}} ->
            ExternalCircuitBreaker.record_success(:api_server)
            body

          _ ->
            ExternalCircuitBreaker.record_failure(:api_server)
            nil
        end
    end
  rescue
    _ ->
      ExternalCircuitBreaker.record_failure(:api_server)
      nil
  end

  @spec post(String.t(), term()) :: :ok | :error
  def post(path, body \\ %{}) do
    case ExternalCircuitBreaker.check(:api_server) do
      {:blocked, _} ->
        :error

      :ok ->
        case Req.post("#{base_url()}#{path}",
               json: body,
               receive_timeout: @timeout,
               retry: false,
               connect_options: [timeout: @timeout]
             ) do
          {:ok, %{status: s}} when s in 200..299 ->
            ExternalCircuitBreaker.record_success(:api_server)
            :ok

          _ ->
            ExternalCircuitBreaker.record_failure(:api_server)
            :error
        end
    end
  rescue
    _ ->
      ExternalCircuitBreaker.record_failure(:api_server)
      :error
  end

  @doc "POST with JSON response body. Custom receive timeout via opts."
  @spec post_json(String.t(), term(), keyword()) :: {:ok, term()} | :error
  def post_json(path, body \\ %{}, opts \\ []) do
    case ExternalCircuitBreaker.check(:api_server) do
      {:blocked, _} ->
        :error

      :ok ->
        recv_timeout = Keyword.get(opts, :receive_timeout, 15_000)

        case Req.post("#{base_url()}#{path}",
               json: body,
               receive_timeout: recv_timeout,
               retry: false,
               connect_options: [timeout: @timeout]
             ) do
          {:ok, %{status: s, body: resp_body}} when s in 200..299 ->
            ExternalCircuitBreaker.record_success(:api_server)
            {:ok, resp_body}

          _ ->
            ExternalCircuitBreaker.record_failure(:api_server)
            :error
        end
    end
  rescue
    _ ->
      ExternalCircuitBreaker.record_failure(:api_server)
      :error
  end
end
