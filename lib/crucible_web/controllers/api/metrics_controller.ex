defmodule CrucibleWeb.Api.MetricsController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  tags(["Metrics"])
  security([%{"cookieAuth" => []}])

  operation(:index,
    summary: "Prometheus metrics",
    description: "Scrapes and returns all Prometheus metrics in text/plain exposition format.",
    responses: [
      ok: {"Metrics text", "text/plain", %OpenApiSpex.Schema{type: :string}}
    ]
  )

  def index(conn, _params) do
    metrics = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end
end
