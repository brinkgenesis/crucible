defmodule Crucible.Safety.CommandClassifier do
  @moduledoc """
  ML-backed classifier for bash commands the pattern analyzer flagged as
  `:warn` (MEDIUM / HIGH).

  Flow:
    1. `Crucible.Safety.BashAnalyzer.analyze/1` picks up obvious cases
       (SAFE → allow, CRITICAL → block).
    2. Anything in between is routed here: we call Haiku via
       `Crucible.Router` with a short prompt; the model returns
       `allow | deny | ask`.
    3. Results are cached per `{command, cwd}` for 10 minutes.
    4. Budget-capped: a single classification must not exceed
       `:max_classification_usd` (default $0.01). If the router reports
       cost above the cap, we degrade to "ask" rather than re-run.
    5. Fails CLOSED: any error returns `:ask` — the caller (usually
       Approval or the Bash tool) can then delegate to user approval or
       deny.
  """

  require Logger

  alias Crucible.Router
  alias Crucible.Safety.BashAnalyzer

  @cache_table :crucible_command_classifier
  @cache_ttl_s 600
  @default_timeout_ms 5_000
  @default_max_cost_usd 0.01

  @type verdict :: :allow | :deny | :ask
  @type classification :: %{
          verdict: verdict(),
          reason: String.t(),
          risk: BashAnalyzer.risk(),
          cost_usd: float(),
          cached?: boolean()
        }

  @doc """
  Decide whether a command is safe to run.

  Combines the AST-style analyzer with an ML verdict when the analyzer
  recommends `:warn`. Returns a classification map.
  """
  @spec classify(command :: String.t(), cwd :: String.t(), opts :: keyword()) ::
          classification()
  def classify(command, cwd, opts \\ []) when is_binary(command) do
    analysis = BashAnalyzer.analyze(command)

    case analysis.recommendation do
      :block ->
        %{
          verdict: :deny,
          reason: "blocked by BashAnalyzer rules: #{Enum.join(analysis.matched_rules, ", ")}",
          risk: analysis.risk,
          cost_usd: 0.0,
          cached?: false
        }

      :allow ->
        %{
          verdict: :allow,
          reason: "safe / low-risk pattern",
          risk: analysis.risk,
          cost_usd: 0.0,
          cached?: false
        }

      :warn ->
        ml_classify(command, cwd, analysis, opts)
    end
  end

  # ── ML verdict ─────────────────────────────────────────────────────────

  defp ml_classify(command, cwd, analysis, opts) do
    key = cache_key(command, cwd)

    case cache_get(key) do
      {:hit, classification} ->
        %{classification | cached?: true}

      :miss ->
        result = invoke_router(command, cwd, analysis, opts)
        cache_put(key, result)
        result
    end
  end

  defp invoke_router(command, cwd, analysis, opts) do
    max_cost = Keyword.get(opts, :max_classification_usd, @default_max_cost_usd)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    prompt = build_prompt(command, cwd, analysis)

    request = %{
      prompt: prompt,
      complexity_hint: 1,
      routing_profile: :yolo_classifier,
      max_tokens: 128,
      temperature: 0.0,
      timeout_ms: timeout
    }

    task = Task.async(fn -> Router.route(request) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} ->
        if response.cost_usd > max_cost do
          Logger.warning(
            "CommandClassifier: classification exceeded budget (#{response.cost_usd} > #{max_cost}); degrading to :ask"
          )

          degrade(analysis, response.cost_usd, "budget exceeded")
        else
          parse_verdict(response.text, analysis, response.cost_usd)
        end

      {:ok, {:error, reason}} ->
        Logger.debug("CommandClassifier: router error — #{inspect(reason)}; degrading to :ask")
        degrade(analysis, 0.0, "router error")

      nil ->
        Logger.debug("CommandClassifier: timeout; degrading to :ask")
        degrade(analysis, 0.0, "timeout")
    end
  end

  defp build_prompt(command, cwd, analysis) do
    """
    You are a safety classifier for shell commands executed by an AI agent.
    Return exactly one word: allow, deny, or ask.

    Guidelines:
      - "allow" if the command is routine and low risk given the cwd
      - "deny" if the command is destructive, exfiltrates data, or escalates privileges
      - "ask" if a human should review before running

    Command: #{String.slice(command, 0, 500)}
    Working directory: #{cwd}
    Rule analysis: risk=#{analysis.risk}, matched=#{Enum.join(analysis.matched_rules, "|")}

    Answer with one word only.
    """
  end

  defp parse_verdict(text, analysis, cost) do
    verdict =
      text
      |> String.downcase()
      |> String.trim()
      |> String.split()
      |> List.first("ask")
      |> case do
        "allow" -> :allow
        "deny" -> :deny
        _ -> :ask
      end

    %{
      verdict: verdict,
      reason: "ML verdict for #{analysis.risk} command",
      risk: analysis.risk,
      cost_usd: cost,
      cached?: false
    }
  end

  defp degrade(analysis, cost, why) do
    %{
      verdict: :ask,
      reason: "degraded to :ask (#{why})",
      risk: analysis.risk,
      cost_usd: cost,
      cached?: false
    }
  end

  # ── cache ──────────────────────────────────────────────────────────────

  defp cache_key(command, cwd) do
    :crypto.hash(:sha256, "#{command}|#{cwd}") |> Base.encode16()
  end

  defp cache_get(key) do
    ensure_table()

    case :ets.lookup(@cache_table, key) do
      [{^key, classification, expires_at}] ->
        if System.monotonic_time(:second) < expires_at do
          {:hit, classification}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      _ ->
        :miss
    end
  end

  defp cache_put(key, classification) do
    ensure_table()
    expires_at = System.monotonic_time(:second) + @cache_ttl_s
    :ets.insert(@cache_table, {key, classification, expires_at})
  end

  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end
end
