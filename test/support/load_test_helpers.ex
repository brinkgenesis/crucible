defmodule Crucible.LoadTestHelpers do
  @moduledoc """
  Mock adapters and StreamData generators for load testing.

  Mock adapters implement `Adapter.Behaviour` but return instantly,
  enabling high-throughput testing without real Claude CLI calls.
  StreamData generators produce random but valid run configurations.
  """

  alias Crucible.Types.{Run, Phase}

  # ── Mock Adapters ──────────────────────────────────────────────────

  defmodule InstantAdapter do
    @moduledoc "Adapter that returns :ok instantly for load testing."
    @behaviour Crucible.Adapter.Behaviour

    @impl true
    def execute_phase(_run, _phase, _prompt, _opts) do
      {:ok, %{status: :completed, output: "mock-ok", exit_status: 0}}
    end

    @impl true
    def cleanup_artifacts(_run, _phase), do: :ok
  end

  defmodule SlowAdapter do
    @moduledoc "Adapter that adds a small random delay (1-10ms) to simulate jitter."
    @behaviour Crucible.Adapter.Behaviour

    @impl true
    def execute_phase(_run, _phase, _prompt, _opts) do
      Process.sleep(:rand.uniform(10))
      {:ok, %{status: :completed, output: "mock-slow", exit_status: 0}}
    end

    @impl true
    def cleanup_artifacts(_run, _phase), do: :ok
  end

  defmodule FailingAdapter do
    @moduledoc "Adapter that always returns an error for failure-path testing."
    @behaviour Crucible.Adapter.Behaviour

    @impl true
    def execute_phase(_run, _phase, _prompt, _opts) do
      {:error, :mock_failure}
    end

    @impl true
    def cleanup_artifacts(_run, _phase), do: :ok
  end

  defmodule FlakyAdapter do
    @moduledoc "Adapter that fails ~30% of the time for resilience testing."
    @behaviour Crucible.Adapter.Behaviour

    @impl true
    def execute_phase(_run, _phase, _prompt, _opts) do
      if :rand.uniform(100) <= 30 do
        {:error, :flaky_failure}
      else
        {:ok, %{status: :completed, output: "mock-flaky-ok", exit_status: 0}}
      end
    end

    @impl true
    def cleanup_artifacts(_run, _phase), do: :ok
  end

  # ── StreamData Generators ──────────────────────────────────────────

  @workflow_types ~w(code-review bug-fix feature refactor ci-pipeline deploy)
  @phase_types [:session, :team, :api, :review_gate, :pr_shepherd, :preflight]
  @execution_types ~w(subscription api hook)

  @doc "Generator for valid run IDs."
  def gen_run_id do
    StreamData.map(
      StreamData.binary(min_length: 8, max_length: 16),
      fn bytes ->
        "run-" <> Base.hex_encode32(bytes, case: :lower, padding: false)
      end
    )
  end

  @doc "Generator for valid Phase structs."
  def gen_phase(index \\ 0) do
    StreamData.fixed_map(%{
      name: StreamData.member_of(["plan", "implement", "review", "test", "deploy"]),
      type: StreamData.member_of(@phase_types),
      timeout_ms: StreamData.member_of([5_000, 10_000, 30_000, 60_000]),
      max_retries: StreamData.integer(0..3)
    })
    |> StreamData.map(fn fields ->
      %Phase{
        id: "phase-#{index}",
        name: fields.name,
        type: fields.type,
        prompt: "Load test prompt for #{fields.name}",
        status: :pending,
        timeout_ms: fields.timeout_ms,
        max_retries: fields.max_retries,
        phase_index: index
      }
    end)
  end

  @doc "Generator for a list of 1-5 sequential phases."
  def gen_phases do
    StreamData.integer(1..5)
    |> StreamData.bind(fn count ->
      0..(count - 1)
      |> Enum.map(&gen_phase/1)
      |> StreamData.fixed_list()
    end)
  end

  @doc "Generator for valid Run structs with random but valid fields."
  def gen_run do
    StreamData.fixed_map(%{
      id: gen_run_id(),
      workflow_type: StreamData.member_of(@workflow_types),
      execution_type: StreamData.member_of(@execution_types),
      budget_usd: StreamData.member_of([10.0, 25.0, 50.0, 100.0]),
      phases: gen_phases()
    })
    |> StreamData.map(fn fields ->
      %Run{
        id: fields.id,
        workflow_type: fields.workflow_type,
        execution_type: fields.execution_type,
        budget_usd: fields.budget_usd,
        phases: fields.phases,
        status: :pending,
        workspace_path: System.tmp_dir!(),
        branch: "load-test-#{:erlang.unique_integer([:positive])}"
      }
    end)
  end

  @doc "Generator for valid workflow config maps (input to WorkflowRunner.create_run/2)."
  def gen_workflow_config do
    StreamData.fixed_map(%{
      name: StreamData.member_of(@workflow_types),
      execution_type: StreamData.member_of(@execution_types),
      budget_usd: StreamData.member_of([10.0, 25.0, 50.0]),
      phase_count: StreamData.integer(1..4)
    })
    |> StreamData.map(fn fields ->
      phases =
        Enum.map(0..(fields.phase_count - 1), fn idx ->
          %{
            "id" => "phase-#{idx}",
            "name" => "Phase #{idx}",
            "type" => Enum.random(~w(session api)),
            "prompt" => "Load test phase #{idx}"
          }
        end)

      %{
        "name" => fields.name,
        "execution_type" => fields.execution_type,
        "budget_usd" => fields.budget_usd,
        "phases" => phases
      }
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  @doc "Create a minimal valid run for testing."
  def minimal_run(overrides \\ %{}) do
    defaults = %{
      id: "load-#{:erlang.unique_integer([:positive])}",
      workflow_type: "load-test",
      status: :pending,
      phases: [
        %Phase{
          id: "phase-0",
          name: "execute",
          type: :session,
          prompt: "test",
          status: :pending,
          phase_index: 0
        }
      ],
      workspace_path: System.tmp_dir!()
    }

    struct(Run, Map.merge(defaults, overrides))
  end

  @doc "Spawn N runs concurrently using Task.async_stream and collect results."
  def spawn_concurrent_runs(runs, execute_fn, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online() * 2)
    timeout = Keyword.get(opts, :timeout, 30_000)

    runs
    |> Task.async_stream(
      fn run -> execute_fn.(run) end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :timeout}
    end)
  end
end
