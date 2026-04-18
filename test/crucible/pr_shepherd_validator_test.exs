defmodule Crucible.PrShepherdValidatorTest do
  use ExUnit.Case, async: true

  alias Crucible.PrShepherdValidator

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "pr_dod_test_#{:erlang.unique_integer([:positive])}")
    runs_dir = Path.join([test_dir, ".claude-flow", "runs"])
    File.mkdir_p!(runs_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, dir: test_dir, runs_dir: runs_dir}
  end

  defp write_dod(dir, run_id, phase_index, report) do
    path = PrShepherdValidator.dod_path(dir, run_id, phase_index)
    File.write!(path, Jason.encode!(report))
  end

  describe "validate/4" do
    test "fails when report is missing", %{dir: dir} do
      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "Missing DoD report"
    end

    test "fails when report JSON is malformed", %{dir: dir, runs_dir: runs_dir} do
      path = Path.join(runs_dir, "run-1-p0.dod.json")
      File.write!(path, "not json{{{")
      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "Malformed"
    end

    test "fails when CI is not green", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{
        status: "done",
        pr: %{number: 42},
        checks: %{ciGreen: false, reviewsResolved: true},
        ui: %{uiFilesChanged: false, screenshotRequired: false, screenshotPresent: false}
      })

      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "CI is not green"
    end

    test "fails when reviews not resolved", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{
        status: "done",
        pr: %{number: 42},
        checks: %{ciGreen: true, reviewsResolved: false},
        ui: %{uiFilesChanged: false, screenshotRequired: false, screenshotPresent: false}
      })

      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "unresolved review"
    end

    test "fails when screenshot required but missing", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{
        status: "done",
        pr: %{number: 42},
        checks: %{ciGreen: true, reviewsResolved: true},
        ui: %{uiFilesChanged: true, screenshotRequired: true, screenshotPresent: false}
      })

      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "screenshot missing"
    end

    test "fails when screenshot present but evidence is empty", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{
        status: "done",
        pr: %{number: 42},
        checks: %{ciGreen: true, reviewsResolved: true},
        ui: %{
          uiFilesChanged: true,
          screenshotRequired: true,
          screenshotPresent: true,
          evidence: ""
        }
      })

      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "evidence is empty"
    end

    test "passes with valid report", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{
        status: "done",
        pr: %{number: 42, url: "https://github.com/test/pr/42"},
        checks: %{ciGreen: true, reviewsResolved: true},
        ui: %{uiFilesChanged: false, screenshotRequired: false, screenshotPresent: false}
      })

      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == true
      assert result.metadata.ci_green == true
    end

    test "passes with UI changes and screenshot evidence", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{
        status: "done",
        pr: %{number: 42},
        checks: %{ciGreen: true, reviewsResolved: true},
        ui: %{
          uiFilesChanged: true,
          screenshotRequired: true,
          screenshotPresent: true,
          evidence: "Screenshot shows the updated UI with dark mode toggle"
        }
      })

      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == true
    end

    test "fails with invalid report schema", %{dir: dir} do
      write_dod(dir, "run-1", 0, %{status: "pending", pr: %{number: -1}})
      result = PrShepherdValidator.validate(dir, "run-1", 0)
      assert result.ok == false
      assert result.reason =~ "Invalid DoD report schema"
    end
  end
end
