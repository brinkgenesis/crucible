defmodule Crucible.RoleAssignment do
  @moduledoc """
  Deterministic file-to-role assignment for multi-agent coding phases.
  Classifies files into backend/runtime/frontend roles based on path patterns,
  ensuring zero overlap between agents.
  """

  @type coder_role :: :coder_backend | :coder_runtime | :coder_frontend

  @role_profiles %{
    coder_backend: %{
      name: "Backend Engineer",
      title: "Senior Backend Developer"
    },
    coder_runtime: %{
      name: "Runtime Engineer",
      title: "Senior Platform Engineer"
    },
    coder_frontend: %{
      name: "Frontend Engineer",
      title: "Senior Frontend Developer"
    }
  }

  @frontend_prefixes ["dashboard/web"]
  @frontend_extensions [".tsx", ".jsx", ".css", ".scss"]

  @runtime_prefixes [
    ".claude",
    "hooks",
    "scripts",
    "monitoring",
    "lib/harness",
    "lib/observability",
    "lib/cli/workflow-executor",
    "lib/cli/workflow-execution-adapters",
    "lib/cli/self-improvement",
    "services/scheduler"
  ]

  @file_path_regex ~r{(?:\.claude|lib|dashboard|tests|workflows|scripts|monitoring|services|agents|hooks)/[\w./@-]+\.\w+}

  @doc """
  Classifies a single file path into a coder role.
  Priority: frontend first, then runtime, default backend.
  """
  @spec classify_file(String.t()) :: coder_role()
  def classify_file(path) do
    normalized = normalize_path(path)

    cond do
      frontend?(normalized) -> :coder_frontend
      runtime?(normalized) -> :coder_runtime
      true -> :coder_backend
    end
  end

  @doc """
  Assigns files deterministically to roles with zero overlap.
  Returns a map of role → file list.
  """
  @spec assign_files([String.t()]) :: %{coder_role() => [String.t()]}
  def assign_files(files) do
    files
    |> Enum.map(&normalize_path/1)
    |> Enum.uniq()
    |> Enum.group_by(&classify_file/1)
    |> Map.merge(%{coder_backend: [], coder_runtime: [], coder_frontend: []}, fn _k, v1, _v2 ->
      v1
    end)
  end

  @doc """
  Returns the dominant role for a set of files (majority vote).
  Test files are excluded from voting. Ties break alphabetically.
  """
  @spec dominant_role([String.t()]) :: coder_role()
  def dominant_role(files) do
    files
    |> Enum.reject(&test_file?/1)
    |> Enum.map(&classify_file/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {role, count} -> {-count, Atom.to_string(role)} end)
    |> case do
      [{role, _} | _] -> role
      [] -> :coder_backend
    end
  end

  @doc """
  Resolves work unit assignments to available roles.
  Each work unit stays atomic (all files → one agent).
  """
  @spec resolve_work_assignments([map()], [coder_role()]) :: %{coder_role() => [map()]}
  def resolve_work_assignments(work_units, available_roles) do
    result = Map.new(available_roles, &{&1, []})

    Enum.reduce(work_units, result, fn unit, acc ->
      files = Map.get(unit, :files, [])
      preferred = dominant_role(files)

      role =
        if preferred in available_roles do
          preferred
        else
          # Load-balance to role with fewest units (deterministic sort for ties)
          available_roles
          |> Enum.sort_by(fn r -> {length(Map.get(acc, r, [])), Atom.to_string(r)} end)
          |> List.first()
        end

      if role do
        Map.update!(acc, role, &[unit | &1])
      else
        acc
      end
    end)
    |> Enum.map(fn {k, v} -> {k, Enum.reverse(v)} end)
    |> Map.new()
  end

  @doc """
  Extracts file paths from plan content using regex.
  """
  @spec extract_plan_files(String.t()) :: [String.t()]
  def extract_plan_files(content) do
    Regex.scan(@file_path_regex, content)
    |> Enum.map(fn [match | _] -> normalize_path(match) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Returns the role profile for a given role."
  @spec role_profile(coder_role()) :: map()
  def role_profile(role),
    do: Map.get(@role_profiles, role, %{name: "Engineer", title: "Developer"})

  # --- Private ---

  @doc false
  def normalize_path(path) do
    path
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> String.replace(~r{^\.//+}, "")
    |> String.replace(~r{^/(Users|home)/[^/]+/[^/]+/}, "")
    |> String.replace("\\", "/")
  end

  defp frontend?(path) do
    Enum.any?(@frontend_prefixes, &String.starts_with?(path, &1)) or
      Enum.any?(@frontend_extensions, &String.ends_with?(path, &1))
  end

  defp runtime?(path) do
    Enum.any?(@runtime_prefixes, &String.starts_with?(path, &1))
  end

  defp test_file?(path) do
    normalized = normalize_path(path)
    String.starts_with?(normalized, "tests/") or String.starts_with?(normalized, "test/")
  end
end
