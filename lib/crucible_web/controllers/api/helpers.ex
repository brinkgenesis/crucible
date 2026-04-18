defmodule CrucibleWeb.Api.Helpers do
  @moduledoc """
  Shared utilities for API controllers and LiveViews.
  Extracts common patterns: safe_call, integer parsing, camelCase key conversion.
  """

  require Logger

  @doc """
  Wraps a function call in try/rescue/catch with a default fallback.
  Logs rescued exceptions and caught exits at warning level for observability.
  """
  def safe_call(fun, default) do
    try do
      fun.()
    rescue
      e ->
        Logger.warning("[safe_call] rescued #{inspect(e.__struct__)}: #{Exception.message(e)}")
        default
    catch
      :exit, reason ->
        Logger.warning("[safe_call] caught exit: #{inspect(reason)}")
        default
    end
  end

  @doc "Parses a positive integer from params with a default."
  def get_int(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      val when is_integer(val) and val > 0 ->
        {:ok, val}

      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "invalid #{key}: must be a positive integer"}
        end

      _ ->
        {:error, "invalid #{key}: must be a positive integer"}
    end
  end

  @doc "Converts a map with snake_case atom keys to camelCase string keys."
  def camel_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      key = k |> to_string() |> to_camel()
      {key, camel_value(v)}
    end)
  end

  def camel_keys(other), do: other

  defp to_camel(str) do
    case String.split(str, "_") do
      [single] -> single
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
    end
  end

  # --- Standardized error responses ---

  @doc """
  Returns a standardized JSON error response.

  All API errors follow the shape: `{error: "error_code", message: "Human readable"}`.
  Optional `details` key for validation errors with field-level info.
  """
  def error_json(conn, status, code, message, details \\ nil) do
    import Plug.Conn
    import Phoenix.Controller, only: [json: 2]

    body =
      %{error: code, message: message}
      |> then(fn b -> if details, do: Map.put(b, :details, details), else: b end)

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc "Paginate a list with limit/offset from query params. Returns {items, meta}."
  def paginate(items, params) when is_list(items) do
    with {:ok, limit} <- get_int(params, "limit", 50),
         {:ok, offset} <- get_int(params, "offset", 0) do
      limit = min(limit, 200)

      paginated = items |> Enum.drop(offset) |> Enum.take(limit)

      meta = %{
        total: length(items),
        limit: limit,
        offset: offset,
        hasMore: offset + limit < length(items)
      }

      {:ok, paginated, meta}
    end
  end

  @doc "Paginate an Ecto query with limit/offset. Returns {items, meta}."
  def paginate_query(queryable, params, repo) do
    import Ecto.Query

    with {:ok, limit} <- get_int(params, "limit", 50),
         {:ok, offset} <- get_int(params, "offset", 0) do
      limit = min(limit, 200)
      total = repo.aggregate(queryable, :count)
      items = queryable |> limit(^limit) |> offset(^offset) |> repo.all()

      meta = %{
        total: total,
        limit: limit,
        offset: offset,
        hasMore: offset + limit < total
      }

      {:ok, items, meta}
    end
  end

  defp camel_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp camel_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp camel_value(list) when is_list(list), do: Enum.map(list, &camel_value/1)
  defp camel_value(map) when is_map(map) and not is_struct(map), do: camel_keys(map)
  defp camel_value(other), do: other
end
