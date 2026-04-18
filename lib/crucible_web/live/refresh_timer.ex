defmodule CrucibleWeb.Live.RefreshTimer do
  @moduledoc """
  Shared timer management for LiveView polling with jitter and backoff.

  Instead of fixed-interval `:timer.send_interval`, this module provides
  `Process.send_after`-based refresh with:
  - **Jitter**: ±20% randomization to prevent thundering herd
  - **Backoff**: doubles the interval (up to max) when data hasn't changed
  - **Reset**: snaps back to base interval when PubSub notifies of changes
  - **Cleanup**: cancel via `cancel/1` in terminate/2

  ## Usage

      # In mount:
      timer = if connected?(socket), do: RefreshTimer.start(5_000)
      assign(socket, refresh_timer: timer)

      # In handle_info(:refresh, socket):
      socket = do_load_data(socket)
      timer = RefreshTimer.tick(socket.assigns.refresh_timer, data_changed?)
      {:noreply, assign(socket, refresh_timer: timer)}

      # On PubSub event (data changed externally):
      timer = RefreshTimer.reset(socket.assigns.refresh_timer)
      {:noreply, assign(socket, refresh_timer: timer) |> load_data()}

      # In terminate:
      RefreshTimer.cancel(socket.assigns[:refresh_timer])
  """

  @type t :: %__MODULE__{
          ref: reference() | nil,
          base_ms: pos_integer(),
          current_ms: pos_integer(),
          max_ms: pos_integer()
        }

  defstruct ref: nil, base_ms: 5_000, current_ms: 5_000, max_ms: 60_000

  @jitter_pct 0.2

  @doc "Start a new refresh timer with jitter."
  @spec start(pos_integer(), keyword()) :: t()
  def start(base_ms, opts \\ []) do
    max_ms = Keyword.get(opts, :max_ms, base_ms * 12)

    timer = %__MODULE__{
      base_ms: base_ms,
      current_ms: base_ms,
      max_ms: max_ms
    }

    schedule(timer)
  end

  @doc """
  Called after each refresh. If data changed, keeps current interval.
  If no change, doubles the interval (capped at max_ms).
  """
  @spec tick(t() | nil, boolean()) :: t() | nil
  def tick(nil, _changed), do: nil

  def tick(%__MODULE__{} = timer, true = _data_changed) do
    schedule(%{timer | current_ms: timer.base_ms})
  end

  def tick(%__MODULE__{} = timer, false = _data_changed) do
    next_ms = min(timer.current_ms * 2, timer.max_ms)
    schedule(%{timer | current_ms: next_ms})
  end

  @doc "Reset to base interval (e.g. on PubSub notification)."
  @spec reset(t() | nil) :: t() | nil
  def reset(nil), do: nil

  def reset(%__MODULE__{} = timer) do
    cancel_ref(timer)
    schedule(%{timer | current_ms: timer.base_ms})
  end

  @doc "Cancel the timer (call in terminate/2)."
  @spec cancel(t() | nil) :: :ok
  def cancel(nil), do: :ok

  def cancel(%__MODULE__{} = timer) do
    cancel_ref(timer)
    :ok
  end

  defp schedule(%__MODULE__{} = timer) do
    cancel_ref(timer)
    jittered = jitter(timer.current_ms)
    ref = Process.send_after(self(), :refresh, jittered)
    %{timer | ref: ref}
  end

  defp cancel_ref(%__MODULE__{ref: nil}), do: :ok
  defp cancel_ref(%__MODULE__{ref: ref}), do: Process.cancel_timer(ref)

  defp jitter(ms) do
    delta = trunc(ms * @jitter_pct)
    ms - delta + :rand.uniform(delta * 2 + 1) - 1
  end
end
