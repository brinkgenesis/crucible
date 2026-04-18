defmodule Crucible.Pipeline.PipelineSupervisor do
  @moduledoc """
  Supervisor for the GenStage streaming pipeline.

  Starts OutputProducer, CostConsumer, and DriftConsumer under supervision
  with `:one_for_all` strategy — if the producer dies, all consumers restart.

  Processes are registered via `Crucible.RunRegistry` for lookup by session_name.
  """

  use Supervisor
  require Logger

  alias Crucible.Pipeline.{OutputProducer, CostConsumer, DriftConsumer}

  @registry Crucible.RunRegistry

  @doc """
  Starts a pipeline for the given session.

  ## Options
    * `:session_name` — tmux session name (required)
    * `:run_id` — workflow run ID
    * `:phase_id` — phase ID
    * `:budget_limit` — cost threshold (default 10.0)
    * `:window_size` — drift sliding window size (default 20)
    * `:repeat_threshold` — repeats before drift alert (default 3)
  """
  def start_pipeline(opts) do
    session_name = opts[:session_name] || raise "PipelineSupervisor requires :session_name"

    case Supervisor.start_link(__MODULE__, opts, name: via(session_name)) do
      {:ok, pid} ->
        Logger.info("PipelineSupervisor: started for #{session_name}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Stops the pipeline for the given session.
  """
  def stop_pipeline(session_name) do
    case lookup(session_name) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end
  end

  @doc """
  Returns the registered name for the OutputProducer of a session.
  """
  def producer_name(session_name), do: :"producer_#{session_name}"

  @doc """
  Looks up the pipeline supervisor pid for a session.
  """
  def lookup(session_name) do
    case Registry.lookup(@registry, {:pipeline, session_name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns whether a pipeline is running for the given session.
  """
  def running?(session_name), do: lookup(session_name) != nil

  # --- Via tuple for Registry naming ---

  defp via(session_name) do
    {:via, Registry, {@registry, {:pipeline, session_name}}}
  end

  # --- Supervisor callbacks ---

  @impl true
  def init(opts) do
    session_name = opts[:session_name]
    run_id = opts[:run_id] || "unknown"
    phase_id = opts[:phase_id] || "p0"
    producer_name = producer_name(session_name)

    children = [
      {OutputProducer,
       [
         name: producer_name,
         session_name: session_name,
         run_id: run_id,
         phase_id: phase_id,
         source: opts[:source]
       ]},
      {CostConsumer,
       [
         name: :"cost_consumer_#{session_name}",
         producer: producer_name,
         session_id: session_name,
         run_id: run_id,
         phase_id: phase_id,
         budget_limit: opts[:budget_limit] || 10.0
       ]},
      {DriftConsumer,
       [
         name: :"drift_consumer_#{session_name}",
         producer: producer_name,
         session_id: session_name,
         run_id: run_id,
         phase_id: phase_id,
         window_size: opts[:window_size] || 20,
         repeat_threshold: opts[:repeat_threshold] || 3
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
