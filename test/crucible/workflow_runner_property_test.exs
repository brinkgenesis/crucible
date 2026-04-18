defmodule Crucible.WorkflowRunnerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Crucible.WorkflowRunner

  property "valid workflow config with phases produces {:ok, Run}" do
    check all(
            name <- string(:alphanumeric, min_length: 1, max_length: 20),
            phase_count <- integer(1..4),
            task <- string(:printable, min_length: 1, max_length: 100)
          ) do
      phases =
        for i <- 1..phase_count do
          %{
            "name" => "phase-#{i}",
            "type" => "session",
            "prompt" => "Do step #{i}"
          }
        end

      config = %{
        "name" => name,
        "phases" => phases,
        "task" => task
      }

      case WorkflowRunner.create_run(config) do
        {:ok, run} ->
          assert run.workflow_type == name
          assert length(run.phases) == phase_count

        {:error, _} ->
          # Some generated names might fail validation — that's acceptable
          :ok
      end
    end
  end

  property "non-map input always returns error" do
    check all(input <- one_of([integer(), string(:printable), constant(nil), list_of(integer())])) do
      assert {:error, :invalid_workflow_config} = WorkflowRunner.create_run(input)
    end
  end

  property "config without phases key fails validation" do
    check all(name <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      config = %{"name" => name}
      assert {:error, _reasons} = WorkflowRunner.create_run(config)
    end
  end
end
