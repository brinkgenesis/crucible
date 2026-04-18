defmodule Crucible.Validation.ManifestTest do
  use ExUnit.Case, async: true

  alias Crucible.Validation.Manifest

  @valid_params %{
    "workflow_name" => "coding-sprint",
    "task_description" => "Implement user auth"
  }

  describe "validate/1 — happy path" do
    test "accepts minimal valid manifest" do
      assert {:ok, manifest} = Manifest.validate(@valid_params)
      assert manifest["workflow_name"] == "coding-sprint"
      assert manifest["task_description"] == "Implement user auth"
      assert manifest["status"] == "pending"
      assert manifest["priority"] == "normal"
      assert is_binary(manifest["run_id"]) and byte_size(manifest["run_id"]) > 0
    end

    test "preserves supplied run_id" do
      params = Map.put(@valid_params, "run_id", "my-custom-id-123")
      assert {:ok, manifest} = Manifest.validate(params)
      assert manifest["run_id"] == "my-custom-id-123"
    end

    test "accepts all optional fields" do
      params =
        @valid_params
        |> Map.put("run_id", "abc-123")
        |> Map.put("plan_note", "some plan note")
        |> Map.put("plan_summary", "summary")
        |> Map.put("card_id", "card-001")
        |> Map.put("priority", "high")

      assert {:ok, manifest} = Manifest.validate(params)
      assert manifest["plan_note"] == "some plan note"
      assert manifest["plan_summary"] == "summary"
      assert manifest["card_id"] == "card-001"
      assert manifest["priority"] == "high"
    end

    test "defaults priority to normal" do
      assert {:ok, manifest} = Manifest.validate(@valid_params)
      assert manifest["priority"] == "normal"
    end

    test "defaults status to pending" do
      assert {:ok, manifest} = Manifest.validate(@valid_params)
      assert manifest["status"] == "pending"
    end

    test "auto-generates run_id when not provided" do
      assert {:ok, m1} = Manifest.validate(@valid_params)
      assert {:ok, m2} = Manifest.validate(@valid_params)
      assert m1["run_id"] != m2["run_id"]
    end
  end

  describe "validate/1 — required fields" do
    test "rejects missing workflow_name" do
      params = Map.delete(@valid_params, "workflow_name")
      assert {:error, errors} = Manifest.validate(params)
      assert {"workflow_name", "is required"} in errors
    end

    test "rejects missing task_description" do
      params = Map.delete(@valid_params, "task_description")
      assert {:error, errors} = Manifest.validate(params)
      assert {"task_description", "is required"} in errors
    end

    test "rejects empty required strings" do
      params = %{"workflow_name" => "", "task_description" => ""}
      assert {:error, errors} = Manifest.validate(params)
      assert {"workflow_name", "is required"} in errors
      assert {"task_description", "is required"} in errors
    end

    test "rejects non-string required fields" do
      params = %{"workflow_name" => 42, "task_description" => true}
      assert {:error, errors} = Manifest.validate(params)
      assert {"workflow_name", "must be a string"} in errors
      assert {"task_description", "must be a string"} in errors
    end

    test "reports all missing fields at once" do
      assert {:error, errors} = Manifest.validate(%{})
      assert length(errors) == 2
    end
  end

  describe "validate/1 — size limits" do
    test "rejects workflow_name over 255 chars" do
      params = Map.put(@valid_params, "workflow_name", String.duplicate("a", 256))
      assert {:error, errors} = Manifest.validate(params)
      assert {"workflow_name", "exceeds maximum length of 255"} in errors
    end

    test "rejects task_description over 10K chars" do
      params = Map.put(@valid_params, "task_description", String.duplicate("x", 10_001))
      assert {:error, errors} = Manifest.validate(params)
      assert {"task_description", "exceeds maximum length of 10000"} in errors
    end

    test "rejects run_id over 64 chars" do
      params = Map.put(@valid_params, "run_id", String.duplicate("a", 65))
      assert {:error, errors} = Manifest.validate(params)
      assert {"run_id", "exceeds maximum length of 64"} in errors
    end

    test "rejects plan_note over 50K chars" do
      params = Map.put(@valid_params, "plan_note", String.duplicate("n", 50_001))
      assert {:error, errors} = Manifest.validate(params)
      assert {"plan_note", "exceeds maximum length of 50000"} in errors
    end

    test "rejects plan_summary over 2K chars" do
      params = Map.put(@valid_params, "plan_summary", String.duplicate("s", 2_001))
      assert {:error, errors} = Manifest.validate(params)
      assert {"plan_summary", "exceeds maximum length of 2000"} in errors
    end

    test "rejects card_id over 128 chars" do
      params = Map.put(@valid_params, "card_id", String.duplicate("c", 129))
      assert {:error, errors} = Manifest.validate(params)
      assert {"card_id", "exceeds maximum length of 128"} in errors
    end

    test "rejects oversized payload" do
      # Build a payload > 100KB via a huge plan_note
      big = String.duplicate("z", 100_001)
      params = Map.put(@valid_params, "plan_note", big)
      assert {:error, errors} = Manifest.validate(params)
      assert Enum.any?(errors, fn {field, _} -> field == "_payload" end)
    end
  end

  describe "validate/1 — format checks" do
    test "rejects run_id with invalid characters" do
      params = Map.put(@valid_params, "run_id", "has spaces!")
      assert {:error, errors} = Manifest.validate(params)
      assert {"run_id", "contains invalid characters"} in errors
    end

    test "accepts run_id with alphanumeric, hyphens, underscores" do
      params = Map.put(@valid_params, "run_id", "my_run-123_ABC")
      assert {:ok, _} = Manifest.validate(params)
    end

    test "rejects invalid priority" do
      params = Map.put(@valid_params, "priority", "ultra")
      assert {:error, errors} = Manifest.validate(params)
      assert {"priority", "must be one of: low, normal, high, critical"} in errors
    end

    test "accepts all valid priorities" do
      for p <- ~w(low normal high critical) do
        params = Map.put(@valid_params, "priority", p)
        assert {:ok, _} = Manifest.validate(params)
      end
    end
  end

  describe "validate/1 — non-map input" do
    test "rejects non-map" do
      assert {:error, [{"_payload", "must be a JSON object"}]} = Manifest.validate("string")
      assert {:error, [{"_payload", "must be a JSON object"}]} = Manifest.validate(nil)
      assert {:error, [{"_payload", "must be a JSON object"}]} = Manifest.validate(42)
    end
  end
end
