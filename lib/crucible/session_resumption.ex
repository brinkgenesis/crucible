defmodule Crucible.SessionResumption do
  @moduledoc """
  Resolves the best session ID for resumption.
  Walks completed session-like phases in reverse order to find the most recent one.
  Maps to `resolveResumeSessionId` in lib/cli/workflow/phase-runner.ts.
  """

  alias Crucible.Types.{Run, Phase}

  @session_like_types [:session, :pr_shepherd, :preflight]

  @doc """
  Resolve the best session ID for resuming a phase.

  Only session-like phases (session, pr_shepherd, preflight) can resume.
  Checks `run.session_resume_chain` first, then walks completed phases in reverse.

  Returns `nil` for non-session-like phases or when no prior session exists.
  """
  @spec resolve_session_id(Run.t(), Phase.t()) :: String.t() | nil
  def resolve_session_id(%Run{} = run, %Phase{} = phase) do
    unless phase.type in @session_like_types do
      nil
    else
      from_chain(run.session_resume_chain, phase.phase_index) ||
        from_completed_phases(run.phases, phase.phase_index)
    end
  end

  # Walk the pre-computed resume chain in reverse from phase_index - 1
  defp from_chain(nil, _phase_index), do: nil

  defp from_chain(chain, phase_index) when is_list(chain) do
    (phase_index - 1)..0//-1
    |> Enum.find_value(fn i ->
      case Enum.at(chain, i) do
        nil -> nil
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end
    end)
  end

  defp from_chain(_, _), do: nil

  # Walk completed phases in reverse looking for a session with a session_id
  defp from_completed_phases(phases, phase_index) when is_list(phases) do
    phases
    |> Enum.with_index()
    |> Enum.filter(fn {_p, i} -> i < phase_index end)
    |> Enum.reverse()
    |> Enum.find_value(fn {p, _i} ->
      if p.type == :session and p.status == :completed and is_binary(p.session_id) and
           p.session_id != "" do
        p.session_id
      end
    end)
  end

  defp from_completed_phases(_, _), do: nil
end
