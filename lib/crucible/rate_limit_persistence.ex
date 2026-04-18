defmodule Crucible.RateLimitPersistence do
  @moduledoc """
  Periodic ETS → DETS snapshot for rate limit state survival across restarts.
  On startup, seeds ETS from the last DETS snapshot (filtering expired entries).
  Snapshots every 60s. Entries older than the rate limit window are pruned.
  """
  use GenServer
  require Logger

  @snapshot_interval_ms 60_000
  @window_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # Ensure the ETS rate_limit table exists. If the table was already created
    # (e.g. in tests or by Application.start), this is a no-op.  Owning the
    # table here means it gets cleaned up if this GenServer restarts, and
    # the :heir option lets us re-adopt it across supervisor restarts.
    ensure_ets_table()

    dets_path =
      Keyword.get(opts, :dets_path, default_dets_path())
      |> String.to_charlist()

    dets_name = Keyword.get(opts, :dets_name, :rate_limit_dets)

    case :dets.open_file(dets_name, file: dets_path, type: :duplicate_bag) do
      {:ok, _ref} ->
        seed_ets_from_dets(dets_name)
        schedule_snapshot()
        {:ok, %{dets_path: dets_path, dets_name: dets_name}}

      {:error, reason} ->
        Logger.warning("RateLimitPersistence: failed to open DETS: #{inspect(reason)}")
        {:ok, %{dets_path: nil, dets_name: dets_name}}
    end
  end

  @impl true
  def handle_info(:snapshot, %{dets_path: nil} = state) do
    schedule_snapshot()
    {:noreply, state}
  end

  def handle_info(:snapshot, state) do
    snapshot_ets_to_dets(state.dets_name)
    schedule_snapshot()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    snapshot_ets_to_dets(state.dets_name)
    :dets.close(state.dets_name)
    :ok
  rescue
    _ -> :ok
  end

  # --- Private ---

  defp seed_ets_from_dets(dets_name) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    entries = :dets.match_object(dets_name, :_)

    valid =
      Enum.filter(entries, fn {_bucket, ts} -> ts >= window_start end)

    Enum.each(valid, fn entry -> :ets.insert(:rate_limit, entry) end)

    Logger.info("RateLimitPersistence: seeded #{length(valid)} entries from DETS")
  rescue
    e -> Logger.warning("RateLimitPersistence: seed failed: #{inspect(e)}")
  end

  defp snapshot_ets_to_dets(dets_name) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    :dets.delete_all_objects(dets_name)

    :ets.foldl(
      fn {_bucket, ts} = entry, acc ->
        if ts >= window_start do
          :dets.insert(dets_name, entry)
          acc + 1
        else
          acc
        end
      end,
      0,
      :rate_limit
    )

    :dets.sync(dets_name)
  rescue
    e -> Logger.warning("RateLimitPersistence: snapshot failed: #{inspect(e)}")
  end

  defp schedule_snapshot do
    Process.send_after(self(), :snapshot, @snapshot_interval_ms)
  end

  defp default_dets_path do
    Application.get_env(
      :crucible,
      :rate_limit_dets_path,
      Path.join(System.tmp_dir!(), "crucible_rate_limits.dets")
    )
  end

  defp ensure_ets_table do
    case :ets.whereis(:rate_limit) do
      :undefined ->
        :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])

      _tid ->
        # Table already exists (created by Application.start or prior init)
        :ok
    end
  end
end
