defmodule Crucible.Status do
  @moduledoc """
  Safe status string → atom conversion.

  BEAM atoms are never garbage-collected, so `String.to_atom/1` on untrusted
  input (user params, JSON from disk, webhook payloads) can exhaust the atom
  table and crash the node. This module provides a whitelist-based converter.
  """

  @status_map %{
    "pending" => :pending,
    "running" => :running,
    "in_progress" => :running,
    "done" => :done,
    "completed" => :done,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "orphaned" => :orphaned,
    "review" => :review,
    "budget_paused" => :budget_paused,
    "timeout" => :timeout
  }

  @doc """
  Convert a status string to a known atom. Returns `:unknown` for
  any value not in the whitelist.

  ## Examples

      iex> Crucible.Status.to_atom("running")
      :running

      iex> Crucible.Status.to_atom("completed")
      :done

      iex> Crucible.Status.to_atom("evil_payload")
      :unknown
  """
  @spec to_atom(String.t() | nil) :: atom()
  def to_atom(nil), do: :unknown
  def to_atom(status) when is_binary(status), do: Map.get(@status_map, status, :unknown)
  def to_atom(_), do: :unknown

  @doc "All recognized status strings."
  @spec known_strings() :: [String.t()]
  def known_strings, do: Map.keys(@status_map)

  @doc "All canonical status atoms (deduplicated)."
  @spec known_atoms() :: [atom()]
  def known_atoms, do: @status_map |> Map.values() |> Enum.uniq()
end
