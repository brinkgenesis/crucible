defmodule CrucibleWeb.Api.ErrorCodes do
  @moduledoc """
  Machine-readable error codes for all API error responses.
  Every error response includes both an HTTP status and a `code` field.
  """

  @type error_response :: %{code: String.t(), message: String.t(), details: map() | nil}

  @spec unauthorized(String.t()) :: error_response()
  def unauthorized(msg \\ "Invalid or missing API key"),
    do: %{code: "unauthorized", message: msg, details: nil}

  @spec forbidden(String.t()) :: error_response()
  def forbidden(msg \\ "Insufficient permissions"),
    do: %{code: "forbidden", message: msg, details: nil}

  @spec not_found(String.t()) :: error_response()
  def not_found(msg \\ "Resource not found"),
    do: %{code: "not_found", message: msg, details: nil}

  @spec rate_limited(integer()) :: error_response()
  def rate_limited(retry_after),
    do: %{
      code: "rate_limited",
      message: "Too many requests",
      details: %{retry_after: retry_after}
    }

  @spec unprocessable(String.t(), map()) :: error_response()
  def unprocessable(msg, details \\ %{}),
    do: %{code: "unprocessable_entity", message: msg, details: details}

  @spec invalid_params(map()) :: error_response()
  def invalid_params(details),
    do: %{code: "invalid_params", message: "Invalid request parameters", details: details}

  @spec internal_error() :: error_response()
  def internal_error,
    do: %{code: "internal_error", message: "An unexpected error occurred", details: nil}

  @spec service_unavailable(String.t()) :: error_response()
  def service_unavailable(msg \\ "Service temporarily unavailable"),
    do: %{code: "service_unavailable", message: msg, details: nil}
end
