defmodule Crucible.Generators do
  @moduledoc "Shared StreamData generators for property-based tests."
  use ExUnitProperties

  def snake_case_key do
    gen all(
          segments <-
            list_of(string(:alphanumeric, min_length: 1, max_length: 8),
              min_length: 1,
              max_length: 3
            )
        ) do
      Enum.join(segments, "_")
    end
  end

  # Use a fixed pool of pre-existing atoms to avoid atom table leaks in tests.
  # The pool is intentionally large so map_of/3 can request unique keys without
  # exhausting a tiny alphabet and flaking under StreamData uniqueness checks.
  @base_segments ~w(
    alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november
    oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu
  )
  @test_atoms Enum.uniq(
                Enum.map(@base_segments, &String.to_atom/1) ++
                  for(
                    left <- @base_segments,
                    right <- @base_segments,
                    left != right,
                    do: String.to_atom("#{left}_#{right}")
                  )
              )

  def snake_case_atom_key do
    member_of(@test_atoms)
  end

  def json_safe_value do
    one_of([integer(), float(), string(:printable, max_length: 50), boolean(), constant(nil)])
  end

  def nested_map(depth \\ 2) do
    if depth <= 0 do
      json_safe_value()
    else
      one_of([
        json_safe_value(),
        map_of(snake_case_atom_key(), nested_map(depth - 1), max_length: 3),
        list_of(nested_map(depth - 1), max_length: 3)
      ])
    end
  end

  def http_method, do: member_of(["GET", "POST", "PUT", "DELETE", "PATCH"])

  def role, do: member_of(["admin", "operator", "viewer"])
  def non_admin_role, do: member_of(["operator", "viewer"])

  # --- Schema generators ---

  def workflow_name do
    gen all(name <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      "wf-#{name}"
    end
  end

  def task_description do
    string(:printable, min_length: 1, max_length: 200)
  end

  def run_status, do: member_of(~w(pending running completed failed cancelled))
  def invalid_run_status, do: member_of(~w(bogus unknown deleted archived))

  def execution_type, do: member_of(~w(subscription api))

  def card_column, do: member_of(~w(ideation unassigned todo in_progress review done))
  def invalid_card_column, do: member_of(~w(deleted archived limbo))

  def card_title do
    string(:printable, min_length: 1, max_length: 100)
  end
end
