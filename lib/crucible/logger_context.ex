defmodule Crucible.LoggerContext do
  @moduledoc """
  Helpers for setting structured Logger metadata context.
  Call these at the start of request handling, GenServer callbacks, etc.
  to ensure all log lines include correlation fields.
  """
  require Logger

  @spec set_request_context(Plug.Conn.t()) :: :ok
  def set_request_context(conn) do
    Logger.metadata(
      request_id: conn.assigns[:request_id],
      tenant_id: extract_tenant(conn),
      method: conn.method,
      path: conn.request_path,
      remote_ip: to_string(:inet.ntoa(conn.remote_ip))
    )

    :ok
  end

  @spec set_run_context(String.t(), String.t()) :: :ok
  def set_run_context(run_id, workflow_name) do
    Logger.metadata(run_id: run_id, workflow: workflow_name)
    :ok
  end

  @spec set_tenant_context(String.t()) :: :ok
  def set_tenant_context(tenant_id) do
    Logger.metadata(tenant_id: tenant_id)
    :ok
  end

  @spec clear() :: :ok
  def clear do
    Logger.metadata([])
    :ok
  end

  defp extract_tenant(conn) do
    case Plug.Conn.get_req_header(conn, "x-tenant-id") do
      [tid] when tid != "" -> tid
      _ -> nil
    end
  end
end
