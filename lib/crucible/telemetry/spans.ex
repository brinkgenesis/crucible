defmodule Crucible.Telemetry.Spans do
  @moduledoc """
  OpenTelemetry span helpers for core orchestrator operations.
  Wraps common span patterns to keep instrumentation DRY.
  """

  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry.Span, as: Span

  @doc """
  Creates a span with the given name and attributes, executes fun,
  records any exception and sets status to ERROR on raise, then
  always ends the span. Returns the fun's return value.
  """
  @spec with_span(String.t(), map(), (-> result)) :: result when result: term()
  def with_span(name, attributes \\ %{}, fun) do
    Tracer.with_span name, %{attributes: attributes} do
      try do
        fun.()
      rescue
        exception ->
          set_error(exception)
          reraise exception, __STACKTRACE__
      end
    end
  end

  @doc "Sets common run attributes on the current span: `run.id` and `run.workflow`."
  @spec set_run_attributes(String.t(), String.t()) :: :ok
  def set_run_attributes(run_id, workflow_name) do
    Tracer.set_attributes([{"run.id", run_id}, {"run.workflow", workflow_name}])
    :ok
  end

  @doc "Records an exception on the current span and sets the status to ERROR."
  @spec set_error(Exception.t()) :: :ok
  def set_error(exception) do
    Span.record_exception(Tracer.current_span_ctx(), exception, [])
    Tracer.set_status(OpenTelemetry.status(:error, Exception.message(exception)))
    :ok
  end

  @doc "Adds a named event with optional attributes to the current span."
  @spec record_event(String.t(), map()) :: :ok
  def record_event(name, attributes \\ %{}) do
    Tracer.add_event(name, Map.to_list(attributes))
    :ok
  end
end
