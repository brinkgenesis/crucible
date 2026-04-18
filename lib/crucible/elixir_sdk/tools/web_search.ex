defmodule Crucible.ElixirSdk.Tools.WebSearch do
  @moduledoc """
  Web search via Anthropic's server-side `web_search` tool.

  Unlike the other tools in this registry, WebSearch is not executed by
  Crucible. Instead, its schema tells Anthropic to enable the built-in
  server-side search tool: the model generates a `server_tool_use` block,
  Anthropic runs the search, and the `web_search_tool_result` content
  comes back in the next stream — we just pass those blocks through to
  the subscriber.

  This module's `run/2` therefore only fires if Crucible mistakenly tries
  to dispatch it locally (misconfiguration); it returns an instructive
  error rather than pretending to search.
  """

  @behaviour Crucible.ElixirSdk.Tool

  @impl true
  def schema do
    # Server-side tools use a `type:` discriminator instead of a custom
    # `input_schema`. The Anthropic client picks up the special type.
    %{
      type: "web_search_20250305",
      name: "web_search",
      max_uses: 5,
      description: "Search the web via Anthropic's server-side search."
    }
  end

  @impl true
  def run(_input, _ctx) do
    {:error,
     "web_search is a server-side tool — Anthropic runs it, not Crucible. " <>
       "Results arrive in the stream as web_search_tool_result blocks."}
  end
end
