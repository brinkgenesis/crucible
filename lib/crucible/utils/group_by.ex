defmodule Crucible.Utils.GroupBy do
  @moduledoc """
  Reusable group-by utilities for collections.

  Provides a generic `group_by/2` wrapper plus domain-specific preset helpers
  for common grouping patterns across LiveView pages and background jobs.

  All functions are pure and deterministic — safe to call from LiveView
  callbacks, background jobs, and concurrent request handlers alike.
  """

  @doc """
  Groups `collection` by the key returned by `key_fn`.

  Items where `key_fn` returns `nil` are grouped under the `:unknown` key.
  Returns a map of `key => [item, ...]`.

  ## Examples

      iex> GroupBy.group_by([%{x: 1}, %{x: 2}, %{x: 1}], & &1.x)
      %{1 => [%{x: 1}, %{x: 1}], 2 => [%{x: 2}]}

      iex> GroupBy.group_by([], & &1.x)
      %{}

      iex> GroupBy.group_by([%{x: nil}], & &1.x)
      %{unknown: [%{x: nil}]}
  """
  @spec group_by(Enumerable.t(), (term() -> term())) :: map()
  def group_by(collection, key_fn) when is_function(key_fn, 1) do
    Enum.group_by(collection, fn item ->
      case key_fn.(item) do
        nil -> :unknown
        key -> key
      end
    end)
  end
end
