defmodule CrucibleWeb.RouteMetrics do
  @moduledoc """
  Native route metrics collector for Phoenix API requests.

  Mirrors the TypeScript dashboard's in-memory SLO snapshot:
  - rolling request counts
  - error rate
  - p95 latency
  - per-route aggregates
  - route-level alerts
  """
  use Agent

  @default_window_ms 5 * 60 * 1000
  @max_samples 25_000
  @error_rate_slo 0.01
  @p95_slo_ms 750.0
  @min_route_volume 20

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @spec record(String.t(), String.t(), integer(), number()) :: :ok
  def record(method, path, status, duration_ms)
      when is_binary(method) and is_binary(path) and is_integer(status) do
    sample = %{
      ts: System.system_time(:millisecond),
      route: normalize_route(path),
      method: method,
      status: status,
      duration_ms: duration_ms * 1.0
    }

    with_agent(:ok, fn ->
      Agent.update(__MODULE__, fn samples ->
        [sample | Enum.take(samples, @max_samples - 1)]
      end)
    end)
  end

  @spec snapshot(non_neg_integer()) :: map()
  def snapshot(window_ms \\ @default_window_ms) do
    with_agent(empty_snapshot(window_ms), fn ->
      now = System.system_time(:millisecond)
      since = now - window_ms

      samples =
        Agent.get(__MODULE__, fn entries ->
          Enum.filter(entries, &(&1.ts >= since))
        end)

      grouped = Enum.group_by(samples, &"#{&1.method} #{&1.route}")

      routes =
        grouped
        |> Enum.map(fn {key, group} ->
          [method | route_parts] = String.split(key, " ")
          route = Enum.join(route_parts, " ")
          durations = group |> Enum.map(& &1.duration_ms) |> Enum.sort()
          total = length(group)
          errors = Enum.count(group, &(&1.status >= 500))

          %{
            "route" => route,
            "method" => method,
            "requestCount" => total,
            "errorCount" => errors,
            "errorRate" => ratio(errors, total),
            "avgMs" => average(durations),
            "p95Ms" => percentile(durations, 95),
            "maxMs" => List.last(durations) || 0.0
          }
        end)
        |> Enum.sort_by(& &1["requestCount"], :desc)

      durations = samples |> Enum.map(& &1.duration_ms) |> Enum.sort()
      total_requests = length(samples)
      total_errors = Enum.count(samples, &(&1.status >= 500))

      %{
        "windowMs" => window_ms,
        "totalRequests" => total_requests,
        "totalErrors" => total_errors,
        "errorRate" => ratio(total_errors, total_requests),
        "p95Ms" => percentile(durations, 95),
        "routes" => routes,
        "alerts" => build_alerts(routes)
      }
    end)
  end

  @spec sample_count() :: non_neg_integer()
  def sample_count do
    with_agent(0, fn -> Agent.get(__MODULE__, &length/1) end)
  end

  @spec reset() :: :ok
  def reset do
    with_agent(:ok, fn -> Agent.update(__MODULE__, fn _ -> [] end) end)
  end

  defp build_alerts(routes) do
    Enum.reduce(routes, [], fn route, acc ->
      if route["requestCount"] < @min_route_volume do
        acc
      else
        reasons =
          []
          |> maybe_add_reason(route["errorRate"] > @error_rate_slo, "error_rate")
          |> maybe_add_reason(route["p95Ms"] > @p95_slo_ms, "p95_latency")

        if reasons == [] do
          acc
        else
          [
            %{
              "route" => route["route"],
              "method" => route["method"],
              "reason" => Enum.join(reasons, "+"),
              "errorRate" => route["errorRate"],
              "p95Ms" => route["p95Ms"]
            }
            | acc
          ]
        end
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p) do
    idx =
      (p / 100 * length(sorted))
      |> Float.ceil()
      |> trunc()
      |> Kernel.-(1)
      |> max(0)
      |> min(length(sorted) - 1)

    Enum.at(sorted, idx, 0.0)
  end

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp empty_snapshot(window_ms) do
    %{
      "windowMs" => window_ms,
      "totalRequests" => 0,
      "totalErrors" => 0,
      "errorRate" => 0.0,
      "p95Ms" => 0.0,
      "routes" => [],
      "alerts" => []
    }
  end

  defp with_agent(default, fun) do
    case Process.whereis(__MODULE__) do
      nil ->
        default

      _pid ->
        fun.()
    end
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp normalize_route(path) do
    path
    |> String.replace(
      ~r/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/i,
      ":id"
    )
    |> String.replace(~r/\/\d+(?=\/|$)/, "/:num")
  end
end
