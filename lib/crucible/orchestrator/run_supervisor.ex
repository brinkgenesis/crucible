defmodule Crucible.Orchestrator.RunSupervisor do
  @moduledoc """
  DynamicSupervisor that starts a per-run GenServer (`RunServer`) for each
  dispatched workflow run. Each run gets its own supervised process with
  independent retry/lifecycle state and crash isolation.

  Uses `:one_for_one` strategy — each run is independent, so a crash in one
  run does not affect others.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a RunServer child for the given run."
  @spec start_run(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_run(run_opts) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Crucible.Orchestrator.RunServer, run_opts}
    )
  end

  @doc "Terminate a RunServer child by pid."
  @spec terminate_run(pid()) :: :ok | {:error, :not_found}
  def terminate_run(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc "Terminate all running RunServer children. Returns count of terminated runs."
  @spec terminate_all() :: non_neg_integer()
  def terminate_all do
    children =
      DynamicSupervisor.which_children(__MODULE__)
      |> Enum.filter(fn {_, pid, _, _} -> is_pid(pid) end)

    Enum.each(children, fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)

    length(children)
  end

  @doc "Count active RunServer children."
  @spec active_count() :: non_neg_integer()
  def active_count do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end
end
