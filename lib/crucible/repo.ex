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
      log_db_error("[Repo.safe_query] connection error", e)
      default

    e in [Postgrex.Error] ->
      log_db_error("[Repo.safe_query] Postgrex error", e)
      default

    e in [Ecto.QueryError] ->
      log_db_error("[Repo.safe_query] query error", e)
      default
  end

  @doc false
  @spec log_db_error(String.t(), Exception.t()) :: :ok
  def log_db_error(context, exception) do
    message = "#{context}: #{Exception.message(exception)}"

    if expected_test_db_error?(exception) do
      Logger.debug(message)
    else
      Logger.warning(message)
    end
  end

  defp expected_test_db_error?(%DBConnection.OwnershipError{}), do: Mix.env() == :test

  defp expected_test_db_error?(%DBConnection.ConnectionError{message: message})
       when is_binary(message) do
    Mix.env() == :test and String.contains?(message, "ownership process")
  end

  defp expected_test_db_error?(_exception), do: false
end
