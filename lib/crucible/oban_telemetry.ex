defmodule Crucible.ObanTelemetry do
  @moduledoc "Attaches handlers for Oban job telemetry events."

  require Logger

  def attach do
    :telemetry.attach(
      "oban-job-exception",
      [:oban, :job, :exception],
      &handle_exception/4,
      nil
    )
  end

  defp handle_exception(_event, _measurements, %{job: job} = meta, _config) do
    worker = job.worker || "unknown"
    kind = Map.get(meta, :kind, :error)
    reason = Map.get(meta, :reason, "unknown")
    Logger.warning("Oban job failed: #{worker} (#{kind}: #{inspect(reason)})")
  end

  defp handle_exception(_, _, _, _), do: :ok
end
