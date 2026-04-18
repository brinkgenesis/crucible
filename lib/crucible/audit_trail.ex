defmodule Crucible.AuditTrail do
  @moduledoc """
  Reads and appends dashboard audit events from the shared JSONL trail used by
  the TypeScript dashboard API.
  """

  alias Crucible.AuditLog

  @type event :: map()

  @spec query(keyword()) :: %{events: [event()], total: non_neg_integer()}
  def query(opts \\ []) do
    path = Keyword.get(opts, :path, audit_log_path())
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    events =
      path
      |> stream_events()
      |> Enum.filter(&matches_filters?(&1, opts))

    %{
      events: events |> Enum.drop(offset) |> Enum.take(limit),
      total: length(events)
    }
  end

  @spec log(map(), keyword()) :: :ok | {:error, term()}
  def log(event, opts \\ []) when is_map(event) do
    path = Keyword.get(opts, :path, audit_log_path())
    dir = Path.dirname(path)

    result =
      with :ok <- File.mkdir_p(dir),
           {:ok, json} <- Jason.encode(event) do
        File.write(path, json <> "\n", [:append])
      end

    # Bridge JSONL events into the audit_events DB table
    bridge_to_db(event)

    result
  end

  defp bridge_to_db(event) do
    action = event["action"] || "unknown"
    {entity_type, entity_id} = parse_resource(event["resource"])

    AuditLog.log(
      entity_type,
      entity_id,
      action,
      Map.get(event, "details", %{}) || %{},
      actor: event["userId"]
    )
  rescue
    _ -> :ok
  end

  defp parse_resource(nil), do: {"unknown", "unknown"}

  defp parse_resource(resource) when is_binary(resource) do
    case String.split(resource, "/", parts: 2) do
      [type, id] -> {type, id}
      [single] -> {"resource", single}
    end
  end

  defp parse_resource(_), do: {"unknown", "unknown"}

  @spec audit_log_path() :: String.t()
  def audit_log_path do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join([repo_root, "data", "audit-log.jsonl"])
  end

  defp stream_events(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&decode_line/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()
    else
      []
    end
  rescue
    _ -> []
  end

  defp decode_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, event} when is_map(event) -> event
      _ -> nil
    end
  end

  defp matches_filters?(event, opts) do
    user_id = Keyword.get(opts, :user_id)
    client_id = Keyword.get(opts, :client_id)
    action = Keyword.get(opts, :action)
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    matches_string?(event["userId"], user_id) and
      matches_string?(event["clientId"], client_id) and
      matches_string?(event["action"], action) and
      within_from?(event["timestamp"], from) and
      within_to?(event["timestamp"], to)
  end

  defp matches_string?(_value, nil), do: true
  defp matches_string?(value, expected), do: value == expected

  defp within_from?(_timestamp, nil), do: true
  defp within_from?(timestamp, from) when is_binary(timestamp), do: timestamp >= from
  defp within_from?(_, _), do: false

  defp within_to?(_timestamp, nil), do: true
  defp within_to?(timestamp, to) when is_binary(timestamp), do: timestamp <= to
  defp within_to?(_, _), do: false
end
