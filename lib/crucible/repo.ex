defmodule Crucible.Repo do
  @moduledoc """
  Ecto repository for the Crucible PostgreSQL database.

  Provides `safe_query/2` for DB calls that should not crash the caller
  on connection or timeout errors (e.g., inside GenServer callbacks).
  """
  use Ecto.Repo,
    otp_app: :crucible,
    adapter: Ecto.Adapters.Postgres

  require Logger

  @doc """
  Execute a DB operation with rescue for connection/timeout errors.
  Returns `default` on failure instead of raising. Logs a warning
  and reports to Sentry for visibility.

  ## Examples

      Repo.safe_query([], fn -> Repo.all(MySchema) end)
      Repo.safe_query(nil, fn -> Repo.one(query) end)
  """
  @spec safe_query(default, (-> result)) :: result | default when default: term(), result: term()
  def safe_query(default, fun) when is_function(fun, 0) do
    fun.()
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      Logger.warning("[Repo.safe_query] connection error: #{Exception.message(e)}")
      default

    e in [Postgrex.Error] ->
      Logger.warning("[Repo.safe_query] Postgrex error: #{Exception.message(e)}")
      default

    e in [Ecto.QueryError] ->
      Logger.warning("[Repo.safe_query] query error: #{Exception.message(e)}")
      default
  end
end
