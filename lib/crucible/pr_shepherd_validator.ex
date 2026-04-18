defmodule Crucible.PrShepherdValidator do
  @moduledoc """
  Full Definition-of-Done validation for PR shepherd phases.
  Validates CI status, review threads, UI screenshot evidence.
  Maps to `validatePrShepherdDoD` in lib/cli/workflow/pr-shepherd-dod.ts.
  """

  require Logger

  @ui_extensions ~w(.tsx .jsx .css .scss .sass .less .html)
  @ui_prefix "dashboard/web/"

  @type validation :: %{
          ok: boolean(),
          report_path: String.t(),
          reason: String.t() | nil,
          metadata: map()
        }

  @doc "Returns the expected DoD report path for a run/phase."
  @spec dod_path(String.t(), String.t(), non_neg_integer()) :: String.t()
  def dod_path(infra_home, run_id, phase_index) do
    Path.join([infra_home, ".claude-flow", "runs", "#{run_id}-p#{phase_index}.dod.json"])
  end

  @doc """
  Validate the PR shepherd DoD report for a phase.
  Checks: report exists, CI green, reviews resolved, UI screenshot evidence.
  """
  @spec validate(String.t(), String.t(), non_neg_integer(), String.t() | nil) :: validation()
  def validate(infra_home, run_id, phase_index, base_commit \\ nil) do
    report_path = dod_path(infra_home, run_id, phase_index)
    metadata = %{}

    unless File.exists?(report_path) do
      throw({:fail, "Missing DoD report JSON", metadata})
    end

    report =
      case parse_report(report_path) do
        {:ok, report} -> report
        {:error, reason} -> throw({:fail, reason, metadata})
      end

    metadata =
      metadata
      |> Map.put(:ci_green, report.ci_green)
      |> Map.put(:reviews_resolved, report.reviews_resolved)
      |> Map.put(:report_ui_files_changed, report.ui_files_changed)
      |> Map.put(:screenshot_required, report.screenshot_required)
      |> Map.put(:screenshot_present, report.screenshot_present)

    unless report.ci_green do
      throw({:fail, "DoD check failed: CI is not green", metadata})
    end

    unless report.reviews_resolved do
      throw({:fail, "DoD check failed: unresolved review threads remain", metadata})
    end

    # Cross-check UI changes against git diff
    metadata =
      if base_commit do
        changed = changed_files_since_base(infra_home, base_commit)
        ui_changed_files = Enum.filter(changed, &ui_file?/1)
        ui_changed_from_git = ui_changed_files != []

        metadata =
          metadata
          |> Map.put(:ui_changed_from_git, ui_changed_from_git)
          |> Map.put(:ui_changed_files, ui_changed_files)

        if report.ui_files_changed != ui_changed_from_git do
          throw({:fail, "DoD check failed: ui.uiFilesChanged does not match git diff", metadata})
        end

        metadata
      else
        metadata
      end

    screenshot_required = Map.get(metadata, :ui_changed_from_git, report.ui_files_changed)

    if screenshot_required and not report.screenshot_required do
      throw(
        {:fail, "DoD check failed: screenshotRequired must be true when UI files changed",
         metadata}
      )
    end

    if screenshot_required and not report.screenshot_present do
      throw({:fail, "DoD check failed: screenshot missing for UI changes", metadata})
    end

    if report.screenshot_present and (report.evidence || "") |> String.trim() == "" do
      throw({:fail, "DoD check failed: screenshot evidence is empty", metadata})
    end

    %{ok: true, report_path: report_path, reason: nil, metadata: metadata}
  catch
    {:fail, reason, meta} ->
      %{
        ok: false,
        report_path: dod_path(infra_home, run_id, phase_index),
        reason: reason,
        metadata: meta
      }
  end

  # --- Private ---

  defp parse_report(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      cond do
        not is_map(data) ->
          {:error, "Invalid DoD report schema"}

        Map.get(data, "status") != "done" ->
          {:error, "Invalid DoD report schema"}

        true ->
          pr = Map.get(data, "pr", %{})
          checks = Map.get(data, "checks", %{})
          ui = Map.get(data, "ui", %{})

          pr_number = Map.get(pr, "number")

          if not is_integer(pr_number) or pr_number <= 0 do
            {:error, "Invalid DoD report schema"}
          else
            {:ok,
             %{
               pr_number: pr_number,
               pr_url: Map.get(pr, "url"),
               ci_green: Map.get(checks, "ciGreen", true) == true,
               reviews_resolved: Map.get(checks, "reviewsResolved", true) == true,
               ui_files_changed: Map.get(ui, "uiFilesChanged") == true,
               screenshot_required: Map.get(ui, "screenshotRequired") == true,
               screenshot_present: Map.get(ui, "screenshotPresent") == true,
               evidence: Map.get(ui, "evidence")
             }}
          end
      end
    else
      _ -> {:error, "Malformed DoD report JSON"}
    end
  end

  defp changed_files_since_base(infra_home, base_commit) do
    case System.cmd("git", ["-C", infra_home, "diff", "--name-only", "#{base_commit}..HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp ui_file?(path) do
    String.starts_with?(path, @ui_prefix) or
      String.downcase(Path.extname(path)) in @ui_extensions
  end
end
