defmodule Crucible.Validation.Manifest do
  @moduledoc """
  Validates and normalizes run manifests at the API boundary.

  Enforces size limits, type constraints, and enum membership to prevent
  cost explosions, DoS payloads, and atom table exhaustion.

  ## Size Limits

  | Field             | Max     |
  |-------------------|---------|
  | Total payload     | 100 KB  |
  | workflow_name     | 255     |
  | task_description  | 10,000  |
  | run_id            | 64      |
  | plan_note         | 50,000  |
  | plan_summary      | 2,000   |
  | card_id           | 128     |
  """

  @max_payload_bytes 100_000
  @priorities ~w(low normal high critical)
  @execution_types ~w(subscription api sdk)

  @doc """
  Validate a run manifest map (string keys).

  Returns `{:ok, validated_manifest}` with defaults applied, or
  `{:error, errors}` where errors is a list of `{field, message}` tuples.

  ## Examples

      iex> Manifest.validate(%{"workflow_name" => "deploy", "task_description" => "ship it"})
      {:ok, %{"workflow_name" => "deploy", "task_description" => "ship it", ...}}

      iex> Manifest.validate(%{})
      {:error, [{"workflow_name", "is required"}, {"task_description", "is required"}]}
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [{String.t(), String.t()}]}
  def validate(params) when is_map(params) do
    errors = []

    # Total payload size check (approximate — Jason.encode is safe on maps)
    errors =
      case check_payload_size(params) do
        :ok -> errors
        {:error, msg} -> [{"_payload", msg} | errors]
      end

    # Required fields
    errors = require_string(errors, params, "workflow_name", max: 255)
    errors = require_string(errors, params, "task_description", max: 10_000)

    # Optional fields
    errors = optional_string(errors, params, "run_id", max: 64, pattern: ~r/^[a-zA-Z0-9_\-]+$/)
    errors = optional_string(errors, params, "plan_note", max: 50_000)
    errors = optional_string(errors, params, "plan_summary", max: 2_000)
    errors = optional_string(errors, params, "card_id", max: 128)
    errors = optional_enum(errors, params, "priority", @priorities)
    errors = optional_enum(errors, params, "execution_type", @execution_types)

    if errors == [] do
      {:ok, build_manifest(params)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, [{"_payload", "must be a JSON object"}]}

  # --- Private ---

  defp build_manifest(params) do
    %{
      "run_id" => Map.get(params, "run_id") || generate_run_id(),
      "workflow_name" => Map.fetch!(params, "workflow_name"),
      "task_description" => Map.fetch!(params, "task_description"),
      "plan_note" => Map.get(params, "plan_note"),
      "plan_summary" => Map.get(params, "plan_summary"),
      "card_id" => Map.get(params, "card_id"),
      "priority" => Map.get(params, "priority", "normal"),
      "execution_type" => Map.get(params, "execution_type", "subscription"),
      "status" => "pending"
    }
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp check_payload_size(params) do
    case Jason.encode(params) do
      {:ok, json} when byte_size(json) > @max_payload_bytes ->
        {:error, "exceeds maximum size of #{@max_payload_bytes} bytes"}

      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, "payload is not serializable"}
    end
  end

  defp require_string(errors, params, field, opts) do
    max = Keyword.fetch!(opts, :max)

    case Map.get(params, field) do
      nil ->
        [{field, "is required"} | errors]

      val when is_binary(val) and byte_size(val) == 0 ->
        [{field, "is required"} | errors]

      val when is_binary(val) ->
        if byte_size(val) > max do
          [{field, "exceeds maximum length of #{max}"} | errors]
        else
          errors
        end

      _ ->
        [{field, "must be a string"} | errors]
    end
  end

  defp optional_string(errors, params, field, opts) do
    max = Keyword.fetch!(opts, :max)
    pattern = Keyword.get(opts, :pattern)

    case Map.get(params, field) do
      nil ->
        errors

      val when is_binary(val) and byte_size(val) == 0 ->
        errors

      val when is_binary(val) ->
        cond do
          byte_size(val) > max ->
            [{field, "exceeds maximum length of #{max}"} | errors]

          pattern && not Regex.match?(pattern, val) ->
            [{field, "contains invalid characters"} | errors]

          true ->
            errors
        end

      _ ->
        [{field, "must be a string"} | errors]
    end
  end

  defp optional_enum(errors, params, field, allowed) do
    case Map.get(params, field) do
      nil ->
        errors

      val when is_binary(val) ->
        if val in allowed do
          errors
        else
          [{field, "must be one of: #{Enum.join(allowed, ", ")}"} | errors]
        end

      _ ->
        [{field, "must be a string"} | errors]
    end
  end
end
