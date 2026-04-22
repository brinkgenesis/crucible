defmodule Crucible.Router.Provider do
  @moduledoc """
  Behaviour for one-shot LLM providers.

  Implementations: Anthropic, Google (Gemini), MiniMax (OpenAI-compat),
  Ollama (OpenAI-compat local). Each provider handles a single
  non-streaming request + response and returns a normalised
  `Crucible.Router.Response` tuple.

  The streaming, tool-use, MCP-aware path lives in `Crucible.ElixirSdk`.
  This is the lightweight path — plan generation, quick Q&A, KPI
  summaries, anything that doesn't need a tool loop.
  """

  @type request :: %{
          required(:prompt) => String.t(),
          optional(:system_prompt) => String.t() | nil,
          optional(:max_tokens) => pos_integer(),
          optional(:temperature) => float() | nil,
          optional(:timeout_ms) => pos_integer(),
          optional(:cache_system) => boolean()
        }

  @type response :: %{
          text: String.t(),
          model_id: String.t(),
          provider: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cost_usd: float(),
          latency_ms: non_neg_integer()
        }

  @callback name() :: String.t()
  @callback request(model_id :: String.t(), request :: request()) ::
              {:ok, response()} | {:error, term()}
  @callback health_check() :: boolean()
end
