defmodule Crucible.PubSub.ManifoldBroadcaster do
  @moduledoc """
  Convenience wrapper for PubSub broadcasting with Manifold fan-out awareness.

  When Manifold is enabled (`:manifold_pubsub` config), all `Phoenix.PubSub.broadcast`
  calls automatically use `ManifoldAdapter` at the adapter level. This module provides
  an explicit API for cases where callers want to bypass Phoenix.PubSub entirely and
  send directly via Manifold through the `TopicRegistry`.

  ## Configuration

      config :crucible, :manifold_pubsub, enabled: true

  ## Usage

      # Standard broadcast (uses ManifoldAdapter transparently when enabled)
      ManifoldBroadcaster.broadcast("inbox:items", {:item_added, item})

      # Direct fan-out via TopicRegistry (bypasses PubSub routing)
      ManifoldBroadcaster.direct_fanout("kanban:cards", {:card_moved, card})

      # Check if Manifold fan-out is active
      ManifoldBroadcaster.enabled?()
  """

  alias Crucible.PubSub.TopicRegistry

  @pubsub Crucible.PubSub

  @doc "Returns true when Manifold-based broadcasting is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:crucible, :manifold_pubsub, [])
    |> Keyword.get(:enabled, false)
  end

  @doc """
  Broadcast a message on a PubSub topic.

  When Manifold is enabled, this goes through `Phoenix.PubSub.broadcast/3` which
  uses `ManifoldAdapter` at the adapter level. When disabled, it falls back to
  standard PG2 dispatch.

  Either way, the call-site is identical — the adapter handles the fan-out strategy.
  """
  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end

  @doc """
  Direct fan-out via TopicRegistry + Manifold, bypassing Phoenix.PubSub routing.

  Only works when Manifold is enabled and processes have subscribed via
  `TopicRegistry.subscribe/1`. Falls back to standard `Phoenix.PubSub.broadcast/3`
  when Manifold is disabled.

  Use this for ultra-high-volume paths where PubSub routing overhead matters.
  """
  @spec direct_fanout(String.t(), term()) :: :ok
  def direct_fanout(topic, message) do
    if enabled?() do
      TopicRegistry.broadcast(topic, message)
    else
      Phoenix.PubSub.broadcast(@pubsub, topic, message)
    end
  end
end
