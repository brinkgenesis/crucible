defmodule Crucible.Idempotency do
  @moduledoc """
  Idempotency key management for run submissions.
  Prevents duplicate runs from being created for the same idempotency key.
  Keys expire after 24 hours.

  The underlying schema uses a composite primary key of `scope` (equivalent to
  tenant_id) and `key`. A stored entry also carries the original `request_hash`,
  `status_code`, and `response` so callers can replay the original response for
  duplicate requests.
  """
  import Ecto.Query, only: [from: 2]

  alias Crucible.Repo
  alias Crucible.Schema.IdempotencyKey

  @ttl_hours 24

  @doc """
  Check whether `key` has already been used by `scope` (tenant/context identifier).

  Returns:
    - `{:ok, :new}` — key is fresh; a placeholder row has been inserted.
    - `{:ok, :duplicate, existing}` — key was already used and is still valid;
      `existing` is the `%IdempotencyKey{}` struct so the caller can replay the
      stored response.
    - `{:error, reason}` — unexpected DB error.

  The placeholder row inserted on `:new` has sentinel values
  (`status_code: 0`, `response: %{}`, `request_hash: "pending"`) that the
  caller is expected to update once the run is created.
  """
  @spec check_and_reserve(String.t(), String.t()) ::
          {:ok, :new} | {:ok, :duplicate, IdempotencyKey.t()} | {:error, term()}
  def check_and_reserve(key, scope) when is_binary(key) and is_binary(scope) do
    case Repo.get_by(IdempotencyKey, key: key, scope: scope) do
      nil ->
        insert_placeholder(key, scope)

      existing ->
        if DateTime.compare(existing.expires_at, DateTime.utc_now()) == :gt do
          {:ok, :duplicate, existing}
        else
          # Expired — delete stale record and allow re-use
          Repo.delete(existing)
          insert_placeholder(key, scope)
        end
    end
  end

  @doc """
  Update the stored idempotency record once the run has been processed.
  Call this after the run is created to replace the placeholder values.
  """
  @spec record_response(String.t(), String.t(), String.t(), integer(), map()) ::
          {:ok, IdempotencyKey.t()} | {:error, term()}
  def record_response(key, scope, request_hash, status_code, response)
      when is_binary(key) and is_binary(scope) do
    case Repo.get_by(IdempotencyKey, key: key, scope: scope) do
      nil ->
        {:error, :not_found}

      existing ->
        changeset =
          IdempotencyKey.changeset(existing, %{
            request_hash: request_hash,
            status_code: status_code,
            response: response
          })

        Repo.update(changeset)
    end
  end

  @doc """
  Delete all expired idempotency keys. Safe to call from a periodic job.
  Returns `{deleted_count, nil}`.
  """
  @spec cleanup_expired() :: {non_neg_integer(), nil}
  def cleanup_expired do
    cutoff = DateTime.utc_now() |> DateTime.add(-@ttl_hours * 3600, :second)
    Repo.delete_all(from k in IdempotencyKey, where: k.expires_at < ^cutoff)
  end

  # Private helpers

  defp insert_placeholder(key, scope) do
    expires_at = DateTime.utc_now() |> DateTime.add(@ttl_hours * 3600, :second)

    changeset =
      IdempotencyKey.changeset(%IdempotencyKey{}, %{
        key: key,
        scope: scope,
        request_hash: "pending",
        status_code: 0,
        response: %{},
        expires_at: expires_at
      })

    case Repo.insert(changeset) do
      {:ok, _record} ->
        {:ok, :new}

      {:error, %Ecto.Changeset{errors: [key: {"has already been taken", _}]}} ->
        # Race: another process inserted between our get_by and insert
        {:ok, :duplicate, Repo.get_by!(IdempotencyKey, key: key, scope: scope)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
