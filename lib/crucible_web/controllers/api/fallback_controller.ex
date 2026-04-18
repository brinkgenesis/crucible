defmodule CrucibleWeb.Api.FallbackController do
  @moduledoc """
  Standardized error response handler for API controllers.

  Controllers can `action_fallback CrucibleWeb.Api.FallbackController`
  and return `{:error, reason}` tuples from actions.
  """
  use CrucibleWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn |> put_status(404) |> json(%{error: "not_found", message: "Resource not found"})
  end

  def call(conn, {:error, :forbidden}) do
    conn |> put_status(403) |> json(%{error: "forbidden", message: "Insufficient permissions"})
  end

  def call(conn, {:error, :unauthorized}) do
    conn |> put_status(401) |> json(%{error: "unauthorized", message: "Authentication required"})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn |> put_status(422) |> json(%{error: "validation_error", details: errors})
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn |> put_status(400) |> json(%{error: "bad_request", message: reason})
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn |> put_status(400) |> json(%{error: to_string(reason), message: to_string(reason)})
  end
end
