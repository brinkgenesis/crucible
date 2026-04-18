defmodule CrucibleWeb.Live.ScopeFilters do
  @moduledoc """
  Shared helpers for client/workspace scope filters across dashboard-style LiveViews.
  """

  @all_scope "all"

  @type option :: %{value: String.t(), label: String.t()}

  @spec all_scope() :: String.t()
  def all_scope, do: @all_scope

  @spec normalize_param(term()) :: String.t()
  def normalize_param(nil), do: @all_scope
  def normalize_param(""), do: @all_scope
  def normalize_param(@all_scope), do: @all_scope
  def normalize_param(value) when is_binary(value), do: value
  def normalize_param(_), do: @all_scope

  @spec query_value(String.t()) :: String.t() | nil
  def query_value(@all_scope), do: nil
  def query_value(value) when is_binary(value), do: value
  def query_value(_), do: nil

  @spec apply_scope_query(map(), String.t(), String.t()) :: map()
  def apply_scope_query(query, client_filter, workspace_filter) when is_map(query) do
    query
    |> put_scope_query("client_id", client_filter)
    |> put_scope_query("workspace", workspace_filter)
  end

  @spec client_options([String.t() | nil]) :: [option()]
  def client_options(client_ids) when is_list(client_ids) do
    ids =
      client_ids
      |> Enum.map(&to_string_or_nil/1)
      |> Enum.reject(&is_nil_or_empty/1)
      |> Enum.uniq()
      |> Enum.sort()

    labels = load_client_labels(ids)

    [%{value: @all_scope, label: "All Clients"}] ++
      Enum.map(ids, fn id ->
        %{value: id, label: Map.get(labels, id, id)}
      end)
  end

  @spec workspace_options([String.t() | nil]) :: [option()]
  def workspace_options(workspaces) when is_list(workspaces) do
    values =
      workspaces
      |> Enum.map(&to_string_or_nil/1)
      |> Enum.reject(&is_nil_or_empty/1)
      |> Enum.uniq()
      |> Enum.sort()

    [%{value: @all_scope, label: "All Workspaces"}] ++
      Enum.map(values, fn value ->
        %{value: value, label: humanize_workspace(value)}
      end)
  end

  @spec matches_client?(String.t() | nil, String.t()) :: boolean()
  def matches_client?(_client_id, @all_scope), do: true
  def matches_client?(client_id, filter), do: to_string_or_nil(client_id) == filter

  @spec matches_workspace?(String.t() | nil, String.t()) :: boolean()
  def matches_workspace?(_workspace, @all_scope), do: true
  def matches_workspace?(workspace, filter), do: to_string_or_nil(workspace) == filter

  defp put_scope_query(query, _key, @all_scope), do: query

  defp put_scope_query(query, key, value) when is_binary(value) and value != "" do
    Map.put(query, key, value)
  end

  defp put_scope_query(query, _key, _value), do: query

  # The Client schema was removed; labels fall back to the raw client_id.
  # When multi-tenant support returns, wire this up to the new lookup.
  defp load_client_labels(_ids), do: %{}

  defp humanize_workspace(value) do
    value
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)

  defp is_nil_or_empty(nil), do: true
  defp is_nil_or_empty(""), do: true
  defp is_nil_or_empty(_), do: false
end
