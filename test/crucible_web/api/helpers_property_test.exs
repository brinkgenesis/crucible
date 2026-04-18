defmodule CrucibleWeb.Api.HelpersPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrucibleWeb.Api.Helpers
  import Crucible.Generators

  describe "camel_keys/1" do
    property "preserves key count" do
      check all(map <- map_of(snake_case_atom_key(), json_safe_value(), max_length: 10)) do
        result = Helpers.camel_keys(map)
        assert map_size(result) == map_size(map)
      end
    end

    property "output keys contain no underscores for multi-word snake_case inputs" do
      # Generate keys that are guaranteed multi-segment snake_case (contain underscore)
      multi_segment_key =
        gen all(
              segments <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 2,
                  max_length: 4
                )
            ) do
          segments |> Enum.join("_") |> String.to_atom()
        end

      check all(map <- map_of(multi_segment_key, json_safe_value(), min_length: 1, max_length: 5)) do
        result = Helpers.camel_keys(map)

        for key <- Map.keys(result) do
          refute String.contains?(key, "_"),
                 "Expected no underscores in camelCase key, got: #{inspect(key)}"
        end
      end
    end

    property "is idempotent on its own output" do
      check all(map <- map_of(snake_case_atom_key(), json_safe_value(), max_length: 10)) do
        once = Helpers.camel_keys(map)
        twice = Helpers.camel_keys(once)
        assert once == twice
      end
    end

    property "preserves scalar values" do
      check all(map <- map_of(snake_case_atom_key(), json_safe_value(), max_length: 10)) do
        result = Helpers.camel_keys(map)
        original_values = map |> Map.values() |> Enum.sort()
        result_values = result |> Map.values() |> Enum.sort()
        assert original_values == result_values
      end
    end

    property "non-map inputs pass through unchanged" do
      check all(value <- json_safe_value()) do
        assert Helpers.camel_keys(value) == value
      end
    end

    property "lists are passed through unchanged" do
      check all(list <- list_of(json_safe_value(), max_length: 10)) do
        assert Helpers.camel_keys(list) == list
      end
    end
  end
end
