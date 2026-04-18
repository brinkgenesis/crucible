defmodule Crucible.LogReader do
  @moduledoc """
  Stateless JSONL log reader for audit, session, savings, cost, and agent logs.
  Reads files on demand — no GenServer, no in-memory state.
  """

  @type_files %{
    audit: "audit.jsonl",
    session: "session-events.jsonl",
    savings: "memory-savings.jsonl",
    cost: "cost-events.jsonl"
  }

  @tail_chunk_size 102_400

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Reads the last N entries from a log type (:cost, :audit, :session, :savings)."
  @spec read_log(atom(), keyword()) :: [map()]
  def read_log(type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    search = Keyword.get(opts, :search)
    logs_dir = Keyword.get(opts, :logs_dir, resolve_logs_dir())

    filename = Map.get(@type_files, type)

    if filename do
      path = Path.join(logs_dir, filename)
      entries = tail_jsonl(path, limit * 2)

      entries
      |> maybe_search(search)
      |> Enum.take(-limit)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Lists agent log files with metadata (id, size, mtime)."
  @spec list_agent_logs(keyword()) :: [map()]
  def list_agent_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    logs_dir = Keyword.get(opts, :logs_dir, resolve_logs_dir())
    agents_dir = Path.join(logs_dir, "agents")

    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.reject(&String.contains?(&1, "teams"))
      |> Enum.map(fn filename ->
        path = Path.join(agents_dir, filename)
        stat = File.stat!(path)
        id = String.trim_trailing(filename, ".jsonl")

        %{
          id: id,
          filename: filename,
          size: stat.size,
          mtime: stat.mtime
        }
      end)
      |> Enum.sort_by(& &1.mtime, :desc)
      |> Enum.take(limit)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Reads entries from a specific agent's log file."
  @spec read_agent_log(String.t(), keyword()) :: [map()]
  def read_agent_log(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    logs_dir = Keyword.get(opts, :logs_dir, resolve_logs_dir())
    path = Path.join([logs_dir, "agents", "#{agent_id}.jsonl"])

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Stream.map(&parse_line/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()
      |> Enum.take(-limit)
    else
      []
    end
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp tail_jsonl(path, limit) do
    if File.exists?(path) do
      case File.stat(path) do
        {:ok, %{size: size}} when size <= @tail_chunk_size ->
          # Small file — read entirely
          path
          |> File.stream!()
          |> Stream.map(&parse_line/1)
          |> Stream.reject(&is_nil/1)
          |> Enum.to_list()
          |> Enum.take(-limit)

        {:ok, %{size: size}} ->
          # Large file — seek to tail
          read_tail(path, size, limit)

        {:error, _} ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_tail(path, size, limit) do
    case :file.open(path, [:read, :binary]) do
      {:ok, fd} ->
        offset = max(size - @tail_chunk_size, 0)
        :file.position(fd, offset)

        case :file.read(fd, @tail_chunk_size) do
          {:ok, data} ->
            :file.close(fd)

            lines = String.split(data, "\n", trim: true)

            # Discard first line if we seeked mid-file (likely partial)
            lines =
              if offset > 0 do
                Enum.drop(lines, 1)
              else
                lines
              end

            lines
            |> Enum.map(&parse_line/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.take(-limit)

          _ ->
            :file.close(fd)
            []
        end

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, event} when is_map(event) -> event
      _ -> nil
    end
  end

  defp maybe_search(entries, nil), do: entries
  defp maybe_search(entries, ""), do: entries

  defp maybe_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn entry ->
      entry
      |> Jason.encode!()
      |> String.downcase()
      |> String.contains?(q)
    end)
  end

  defp resolve_logs_dir do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join(repo_root, ".claude-flow/logs")
  end
end
