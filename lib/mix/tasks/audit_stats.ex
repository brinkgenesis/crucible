defmodule Mix.Tasks.AuditStats do
  @moduledoc """
  Reports audit event counts grouped by entity type.

      $ mix audit_stats
      $ mix audit_stats --since 2024-01-01

  Prints a table of entity types and their event counts, sorted by count
  descending.
  """

  use Mix.Task

  import Ecto.Query

  @shortdoc "Report audit event counts by entity type"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [since: :string])

    query =
      from(e in Crucible.Schema.AuditEvent,
        group_by: e.entity_type,
        select: {e.entity_type, count(e.id)},
        order_by: [desc: count(e.id)]
      )

    query = maybe_filter_since(query, opts[:since])

    results = Crucible.Repo.all(query)

    if results == [] do
      Mix.shell().info("No audit events found.")
    else
      total = Enum.reduce(results, 0, fn {_type, count}, acc -> acc + count end)

      header = String.pad_trailing("entity_type", 30) <> "| count"
      separator = String.duplicate("-", 30) <> "|" <> String.duplicate("-", 10)

      Mix.shell().info(header)
      Mix.shell().info(separator)

      Enum.each(results, fn {entity_type, count} ->
        Mix.shell().info(String.pad_trailing(entity_type, 30) <> "| #{count}")
      end)

      Mix.shell().info(separator)
      Mix.shell().info(String.pad_trailing("TOTAL", 30) <> "| #{total}")
    end
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, since_str) do
    case Date.from_iso8601(since_str) do
      {:ok, date} ->
        {:ok, datetime} = NaiveDateTime.new(date, ~T[00:00:00])
        since = DateTime.from_naive!(datetime, "Etc/UTC")
        from(e in query, where: e.occurred_at >= ^since)

      {:error, _} ->
        Mix.raise(
          "Invalid --since date: #{since_str}. Expected ISO 8601 format (e.g. 2024-01-01)"
        )
    end
  end
end
