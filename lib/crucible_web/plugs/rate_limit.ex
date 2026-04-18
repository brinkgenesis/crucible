defmodule CrucibleWeb.Plugs.RateLimit do
  @moduledoc """
  Per-IP and per-tenant rate limiting using ETS.

  Enforces separate limits for read (GET/HEAD) and write (POST/PUT/DELETE) requests.
  When a tenant ID is present (via `x-tenant-id` header or Bearer token), a second
  tenant-scoped bucket is also checked with higher limits.

  The :rate_limit ETS table is created at application start (see Application.start/2).
  """
  import Plug.Conn

  @behaviour Plug

  @default_ip_read_limit 120
  @default_ip_write_limit 20
  @default_tenant_read_limit 300
  @default_tenant_write_limit 60
  @window_ms 60_000
  @window_secs div(@window_ms, 1000)

  @spec init(keyword()) :: keyword()
  @impl true
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @impl true
  def call(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    is_read = conn.method in ["GET", "HEAD"]

    with {:ok, ip_remaining, limit} <- check_ip_limit(ip, is_read) do
      reset = System.os_time(:second) + @window_secs

      case extract_tenant(conn) do
        nil ->
          conn
          |> put_rate_limit_headers(limit, ip_remaining, reset)

        tenant_id ->
          check_tenant_limit(conn, tenant_id, is_read, limit, ip_remaining, reset)
      end
    else
      :rate_limited -> rate_limited_response(conn)
    end
  end

  defp check_ip_limit(ip, is_read) do
    {limit, bucket} =
      if is_read,
        do: {ip_read_limit(), {ip, :read}},
        else: {ip_write_limit(), {ip, :write}}

    case check_bucket(bucket, limit) do
      {:ok, remaining} -> {:ok, remaining, limit}
      :rate_limited -> :rate_limited
    end
  end

  defp check_tenant_limit(conn, tenant_id, is_read, ip_limit, ip_remaining, reset) do
    {limit, bucket} =
      if is_read,
        do: {tenant_read_limit(), {:tenant, tenant_id, :read}},
        else: {tenant_write_limit(), {:tenant, tenant_id, :write}}

    case check_bucket(bucket, limit) do
      {:ok, tenant_remaining} ->
        # Use the more restrictive remaining count for the headers
        remaining = min(ip_remaining, tenant_remaining)
        effective_limit = min(ip_limit, limit)

        conn
        |> put_rate_limit_headers(effective_limit, remaining, reset)

      :rate_limited ->
        rate_limited_response(conn)
    end
  end

  defp check_bucket(bucket, limit) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    # Purge expired entries
    :ets.select_delete(:rate_limit, [{{bucket, :"$1"}, [{:<, :"$1", window_start}], [true]}])

    # Insert-then-count eliminates the TOCTOU race between the old
    # count-then-insert approach. Concurrent requests now always see each
    # other's entries. If we exceed the limit, we roll back the insertion.
    :ets.insert(:rate_limit, {bucket, now})

    count =
      :ets.select_count(:rate_limit, [{{bucket, :"$1"}, [{:>=, :"$1", window_start}], [true]}])

    if count > limit do
      # Over limit — remove the speculative entry we just inserted
      :ets.match_delete(:rate_limit, {bucket, now})
      :rate_limited
    else
      {:ok, limit - count}
    end
  end

  defp put_rate_limit_headers(conn, limit, remaining, reset) do
    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset))
  end

  defp extract_tenant(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant_id] when tenant_id != "" -> tenant_id
      _ -> extract_bearer_tenant(conn)
    end
  end

  defp extract_bearer_tenant(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> token
      _ -> nil
    end
  end

  defp rate_limited_response(conn) do
    :telemetry.execute(
      [:crucible, :rate_limit, :hit],
      %{count: 1},
      %{ip: to_string(:inet.ntoa(conn.remote_ip)), path: conn.request_path, method: conn.method}
    )

    conn
    |> put_resp_header("retry-after", to_string(@window_secs))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{error: "rate_limited", retry_after: @window_secs}))
    |> halt()
  end

  defp ip_read_limit, do: get_limit(:ip_read_limit, @default_ip_read_limit)
  defp ip_write_limit, do: get_limit(:ip_write_limit, @default_ip_write_limit)
  defp tenant_read_limit, do: get_limit(:tenant_read_limit, @default_tenant_read_limit)
  defp tenant_write_limit, do: get_limit(:tenant_write_limit, @default_tenant_write_limit)

  defp get_limit(key, default) do
    Application.get_env(:crucible, :rate_limits, [])
    |> Keyword.get(key, default)
  end
end
