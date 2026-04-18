defmodule CrucibleWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.

  All responses use the standardized shape:
    {"error": {"code": "...", "message": "...", "details": null}}
  """

  alias CrucibleWeb.Api.ErrorCodes

  def render("401.json", _assigns) do
    %{error: ErrorCodes.unauthorized()}
  end

  def render("403.json", _assigns) do
    %{error: ErrorCodes.forbidden()}
  end

  def render("404.json", _assigns) do
    %{error: ErrorCodes.not_found()}
  end

  def render("422.json", _assigns) do
    %{error: ErrorCodes.unprocessable("Unprocessable entity")}
  end

  def render("429.json", _assigns) do
    %{error: ErrorCodes.rate_limited(60)}
  end

  def render("503.json", _assigns) do
    %{error: ErrorCodes.service_unavailable()}
  end

  def render("500.json", _assigns) do
    %{error: ErrorCodes.internal_error()}
  end

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    %{error: %{code: "error", message: message, details: nil}}
  end
end
