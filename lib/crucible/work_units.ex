defmodule Crucible.WorkUnits do
  @moduledoc """
  YAML parsing and validation for work unit definitions.
  Work units are semantic tasks with file ownership and acceptance criteria,
  extracted from plan notes fenced in ```work-units blocks.
  """

  @type work_unit :: %{
          id: String.t(),
          description: String.t(),
          files: [String.t()],
          read_files: [String.t()],
          context_boundary: [String.t()],
          depends_on: [String.t()],
          acceptance_criteria: [String.t()]
        }

  @fence_regex ~r/```work-units\s*\n([\s\S]*?)```/

  @doc """
  Extracts work units from plan content (markdown with YAML fences).
  Returns a list of parsed work unit maps.
  """
  @spec extract(String.t()) :: [work_unit()]
  def extract(content) when is_binary(content) do
    case Regex.run(@fence_regex, content) do
      [_, yaml_content] ->
        case YamlElixir.read_from_string(yaml_content) do
          {:ok, units} when is_list(units) ->
            units
            |> Enum.filter(&valid_unit?/1)
            |> Enum.map(&normalize_unit/1)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  def extract(_), do: []

  @doc """
  Validates a list of work units. Returns a list of error strings (empty = valid).
  """
  @spec validate([work_unit()]) :: [String.t()]
  def validate(units) when is_list(units) do
    errors = []

    # Check for missing/duplicate IDs
    ids = Enum.map(units, & &1.id)
    dup_ids = ids -- Enum.uniq(ids)

    errors =
      if dup_ids != [],
        do: ["Duplicate work unit IDs: #{Enum.join(dup_ids, ", ")}" | errors],
        else: errors

    # Per-unit validation
    unit_errors =
      Enum.flat_map(units, fn unit ->
        errs = []
        errs = if blank?(unit.id), do: ["Work unit missing id" | errs], else: errs

        errs =
          if blank?(unit.description),
            do: ["Work unit #{unit.id}: missing description" | errs],
            else: errs

        errs =
          if unit.files == [],
            do: ["Work unit #{unit.id}: must have at least one file" | errs],
            else: errs

        errs =
          if unit.acceptance_criteria == [],
            do: ["Work unit #{unit.id}: must have at least one acceptance criterion" | errs],
            else: errs

        errs
      end)

    # Check dangling depends_on references
    id_set = MapSet.new(ids)

    dangling_errors =
      units
      |> Enum.flat_map(fn unit ->
        unit.depends_on
        |> Enum.reject(&MapSet.member?(id_set, &1))
        |> Enum.map(&"Work unit #{unit.id}: depends on unknown unit '#{&1}'")
      end)

    errors ++ unit_errors ++ dangling_errors
  end

  @doc """
  Formats work units back into a markdown-fenced YAML block.
  """
  @spec format_for_plan([work_unit()]) :: String.t()
  def format_for_plan(units) when is_list(units) do
    yaml_units =
      Enum.map(units, fn unit ->
        base = %{
          "id" => unit.id,
          "description" => unit.description,
          "files" => unit.files,
          "acceptanceCriteria" => unit.acceptance_criteria
        }

        base =
          if unit.read_files != [], do: Map.put(base, "readFiles", unit.read_files), else: base

        base =
          if unit.context_boundary != [],
            do: Map.put(base, "contextBoundary", unit.context_boundary),
            else: base

        base =
          if unit.depends_on != [], do: Map.put(base, "dependsOn", unit.depends_on), else: base

        base
      end)

    yaml = units_to_yaml(yaml_units)
    "```work-units\n#{yaml}\n```"
  end

  # --- Private ---

  defp valid_unit?(unit) when is_map(unit) do
    Map.has_key?(unit, "id") and Map.has_key?(unit, "description")
  end

  defp valid_unit?(_), do: false

  defp normalize_unit(raw) do
    %{
      id: Map.get(raw, "id"),
      description: Map.get(raw, "description"),
      files: Map.get(raw, "files", []) |> List.wrap(),
      read_files: (Map.get(raw, "readFiles") || Map.get(raw, "read_files") || []) |> List.wrap(),
      context_boundary:
        (Map.get(raw, "contextBoundary") || Map.get(raw, "context_boundary") || []) |> List.wrap(),
      depends_on: (Map.get(raw, "dependsOn") || Map.get(raw, "depends_on") || []) |> List.wrap(),
      acceptance_criteria:
        (Map.get(raw, "acceptanceCriteria") || Map.get(raw, "acceptance_criteria") || [])
        |> List.wrap()
    }
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp units_to_yaml(units) do
    units
    |> Enum.map(fn unit ->
      lines = ["- id: #{unit["id"]}", "  description: #{unit["description"]}"]

      lines = lines ++ format_yaml_list("files", unit["files"])
      lines = lines ++ format_yaml_list("acceptanceCriteria", unit["acceptanceCriteria"])

      lines =
        if Map.has_key?(unit, "readFiles"),
          do: lines ++ format_yaml_list("readFiles", unit["readFiles"]),
          else: lines

      lines =
        if Map.has_key?(unit, "contextBoundary"),
          do: lines ++ format_yaml_list("contextBoundary", unit["contextBoundary"]),
          else: lines

      lines =
        if Map.has_key?(unit, "dependsOn"),
          do: lines ++ format_yaml_list("dependsOn", unit["dependsOn"]),
          else: lines

      Enum.join(lines, "\n")
    end)
    |> Enum.join("\n")
  end

  defp format_yaml_list(key, values) when is_list(values) do
    ["  #{key}:"] ++ Enum.map(values, &"    - #{&1}")
  end

  defp format_yaml_list(_, _), do: []
end
