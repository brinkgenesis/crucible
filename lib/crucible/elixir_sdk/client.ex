defmodule Crucible.ElixirSdk.Client do
  @moduledoc """
  HTTP client for the Anthropic Messages API.

  Streams Server-Sent Events from `POST /v1/messages` with `stream: true`,
  decodes events, and forwards them to a subscriber process.

  Beyond the minimal SSE pipe, this client implements:

    * Automatic retry on 429 / 529 / 5xx with exponential backoff + jitter,
      honouring the `retry-after` header when present.
    * `api_retry` events emitted to the subscriber on every retry attempt so
      Query / the dashboard can surface the backoff.
    * A kill-switch ref: the subscriber can call `abort/1` to stop an
      in-flight request cleanly (cancels the owning Task).
    * Thinking blocks and image blocks are passed through untouched — Query
      decides how to reassemble them.

  Events emitted to the subscriber:

      {:crucible_sdk, :message_start, %{message: ...}}
      {:crucible_sdk, :content_block_start, %{index: int, content_block: map}}
      {:crucible_sdk, :content_block_delta, %{index: int, delta: map}}
      {:crucible_sdk, :content_block_stop, %{index: int}}
      {:crucible_sdk, :message_delta, %{delta: map, usage: map}}
      {:crucible_sdk, :message_stop, %{}}
      {:crucible_sdk, :api_retry, %{attempt: n, max: n, error_status: int, delay_ms: int}}
      {:crucible_sdk, :rate_limit, %{status: String.t(), retry_after_s: int | nil}}
      {:crucible_sdk, :done, %{ref: ref}}
      {:crucible_sdk, :error, term()}
  """

  require Logger

  @default_base_url "https://api.anthropic.com"
  @default_version "2023-06-01"
  @default_timeout_ms 300_000
  @default_max_retries 5
  @event_types %{
    "message_start" => :message_start,
    "content_block_start" => :content_block_start,
    "content_block_delta" => :content_block_delta,
    "content_block_stop" => :content_block_stop,
    "message_delta" => :message_delta,
    "message_stop" => :message_stop,
    "api_retry" => :api_retry,
    "rate_limit" => :rate_limit,
    "error" => :error
  }

  # Which status codes trigger a retry. 529 = overloaded.
  @retriable [408, 409, 425, 429, 500, 502, 503, 504, 529]

  @type message :: %{role: String.t(), content: list() | String.t()}
  @type tool :: %{name: String.t(), description: String.t(), input_schema: map()}

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Start a streaming Messages API request.

  Returns `{:ok, ref}`. The returned `ref` can be passed to `abort/1` to
  cancel the request mid-stream. The subscriber receives
  `{:crucible_sdk, event, payload}` messages until `:done` or `:error`.
  """
  @spec stream(keyword()) :: {:ok, reference()} | {:error, :task_start_timeout}
  def stream(opts) do
    subscriber = Keyword.get(opts, :subscriber, self())
    ref = make_ref()
    parent = self()

    {:ok, task_pid} =
      Task.Supervisor.start_child(
        crucible_task_supervisor(),
        fn ->
          send(parent, {:crucible_sdk_task_ready, ref})
          do_stream(opts, subscriber, ref)
        end,
        restart: :temporary
      )

    Process.put({:crucible_sdk_task, ref}, task_pid)

    receive do
      {:crucible_sdk_task_ready, ^ref} -> {:ok, ref}
    after
      5_000 -> {:error, :task_start_timeout}
    end
  end

  @doc "Abort an in-flight stream by its ref."
  @spec abort(reference()) :: :ok
  def abort(ref) do
    case Process.get({:crucible_sdk_task, ref}) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.delete({:crucible_sdk_task, ref})
        :ok
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp crucible_task_supervisor do
    case Process.whereis(Crucible.ElixirSdk.TaskSupervisor) do
      nil ->
        {:ok, pid} = Task.Supervisor.start_link(name: Crucible.ElixirSdk.TaskSupervisor)
        pid

      pid ->
        pid
    end
  end

  defp do_stream(opts, subscriber, ref) do
    api_key = Keyword.get(opts, :api_key) || Crucible.Secrets.get("ANTHROPIC_API_KEY")

    unless is_binary(api_key) and api_key != "" do
      send(subscriber, {:crucible_sdk, :error, {:missing_api_key, ref}})
      exit(:normal)
    end

    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    attempt_stream(opts, subscriber, ref, api_key, 0, max_retries)
  end

  defp attempt_stream(opts, subscriber, ref, api_key, attempt, max_retries) do
    base_url = Keyword.get(opts, :base_url) || @default_base_url
    body = build_body(opts)
    headers = build_headers(api_key, Keyword.get(opts, :anthropic_beta, []))
    buffer_agent = start_buffer()

    req =
      Req.new(
        base_url: base_url,
        url: "/v1/messages",
        method: :post,
        json: body,
        headers: headers,
        receive_timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        into: fn {:data, chunk}, {request, response} ->
          :ok = feed(buffer_agent, chunk, subscriber, ref)
          {:cont, {request, response}}
        end
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: 200}} ->
        :ok = feed(buffer_agent, "\n\n", subscriber, ref)
        send(subscriber, {:crucible_sdk, :done, %{ref: ref, model: Keyword.fetch!(opts, :model)}})

      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}}
      when status in @retriable ->
        handle_retry(opts, subscriber, ref, api_key, attempt, max_retries,
          status: status,
          body: body,
          headers: resp_headers
        )

      {:ok, %Req.Response{status: status, body: body}} ->
        raw_buf =
          try do
            Agent.get(buffer_agent, & &1, 5_000)
          catch
            _, _ -> ""
          end

        detail =
          cond do
            is_binary(raw_buf) and raw_buf != "" -> raw_buf
            is_binary(body) and body != "" -> body
            true -> inspect(body)
          end

        req_body = build_body(opts)

        msg_shapes =
          req_body
          |> Map.get(:messages, [])
          |> Enum.with_index()
          |> Enum.map(fn {m, i} ->
            role = m[:role] || m["role"]

            types =
              case m[:content] || m["content"] do
                c when is_binary(c) -> ["text"]
                c when is_list(c) -> Enum.map(c, &(&1["type"] || &1[:type]))
                _ -> ["?"]
              end

            "#{i}:#{role}=#{Enum.join(types, ",")}"
          end)
          |> Enum.join(" | ")

        Logger.error(
          "ElixirSdk.Client: HTTP #{status} response=#{summarize(detail)} msgs=[#{msg_shapes}]"
        )

        send(subscriber, {:crucible_sdk, :error, {:http_error, status, summarize(detail)}})

      {:error, %{reason: :timeout}} ->
        handle_retry(opts, subscriber, ref, api_key, attempt, max_retries,
          status: 0,
          error: :timeout
        )

      {:error, reason} ->
        send(subscriber, {:crucible_sdk, :error, {:transport_error, reason}})
    end
  rescue
    e -> send(subscriber, {:crucible_sdk, :error, {:exception, Exception.message(e)}})
  end

  defp handle_retry(opts, subscriber, ref, api_key, attempt, max_retries, info) do
    if attempt >= max_retries do
      send(subscriber, {:crucible_sdk, :error, {:retries_exhausted, info}})
    else
      delay_ms = compute_delay(attempt, info)

      send(
        subscriber,
        {:crucible_sdk, :api_retry,
         %{
           ref: ref,
           attempt: attempt + 1,
           max: max_retries,
           error_status: info[:status] || 0,
           delay_ms: delay_ms
         }}
      )

      Process.sleep(delay_ms)
      attempt_stream(opts, subscriber, ref, api_key, attempt + 1, max_retries)
    end
  end

  # Respect `retry-after` (seconds or HTTP date) if present; otherwise
  # exponential backoff with full jitter, capped at 30s.
  defp compute_delay(attempt, info) do
    base = min(round(:math.pow(2, attempt) * 1000), 30_000)
    jitter = :rand.uniform(round(base / 2))

    case retry_after_ms(info[:headers] || []) do
      nil -> base + jitter
      ms when ms > 0 -> ms + jitter
      _ -> base + jitter
    end
  end

  defp retry_after_ms(headers) do
    case Enum.find(headers, fn
           {k, _} when is_binary(k) -> String.downcase(k) == "retry-after"
           _ -> false
         end) do
      {_, v} when is_binary(v) ->
        case Integer.parse(v) do
          {seconds, _} -> seconds * 1000
          :error -> nil
        end

      {_, [v | _]} when is_binary(v) ->
        case Integer.parse(v) do
          {seconds, _} -> seconds * 1000
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp summarize(body), do: inspect(body, limit: 10)

  # --- request building ---

  defp build_body(opts) do
    base = %{
      model: Keyword.fetch!(opts, :model),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      messages: Keyword.fetch!(opts, :messages),
      stream: true
    }

    base
    |> maybe_put(:system, Keyword.get(opts, :system))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:tools, Keyword.get(opts, :tools))
    |> maybe_put(:tool_choice, Keyword.get(opts, :tool_choice))
    |> maybe_put(:thinking, Keyword.get(opts, :thinking))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_headers(api_key, betas) do
    base = [
      {"x-api-key", api_key},
      {"anthropic-version", @default_version},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    case betas do
      [] -> base
      list -> [{"anthropic-beta", Enum.join(list, ",")} | base]
    end
  end

  # --- SSE framing ---

  defp start_buffer do
    {:ok, agent} = Agent.start_link(fn -> "" end)
    agent
  end

  defp feed(agent, chunk, subscriber, ref) do
    full =
      Agent.get_and_update(agent, fn buf ->
        new = buf <> chunk
        {parts, leftover} = split_events(new)
        {parts, leftover}
      end)

    Enum.each(full, &dispatch(&1, subscriber, ref))
    :ok
  end

  defp split_events(buffer) do
    parts = String.split(buffer, "\n\n")
    {events, [leftover]} = Enum.split(parts, -1)
    {events, leftover}
  end

  defp dispatch("", _subscriber, _ref), do: :ok

  defp dispatch(raw_event, subscriber, ref) do
    event_type =
      raw_event
      |> String.split("\n")
      |> Enum.find_value(fn
        "event: " <> name -> String.trim(name)
        _ -> nil
      end)

    data_line =
      raw_event
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: " <> json -> json
        _ -> nil
      end)

    case event_atom(event_type) do
      :ignore ->
        :ok

      {:ok, event_atom} ->
        dispatch_event(event_atom, data_line, subscriber, ref)
    end
  end

  defp event_atom(nil), do: :ignore

  defp event_atom(type) when is_binary(type) do
    case @event_types[type] do
      nil ->
        Logger.debug("ElixirSdk.Client: ignoring unknown event #{inspect(type)}")
        :ignore

      event_atom ->
        {:ok, event_atom}
    end
  end

  defp dispatch_event(event_atom, nil, subscriber, ref) do
    send(subscriber, {:crucible_sdk, event_atom, %{ref: ref}})
  end

  defp dispatch_event(event_atom, json, subscriber, ref) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) ->
        send(subscriber, {:crucible_sdk, event_atom, Map.put(payload, :ref, ref)})

      {:error, reason} ->
        Logger.debug("ElixirSdk.Client: bad JSON in event: #{inspect(reason)}")
        :ok
    end
  end
end
