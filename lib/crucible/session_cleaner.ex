defmodule Crucible.SessionCleaner do
  @moduledoc """
  Oban worker that cleans up expired sessions hourly.
  Configured in `config.exs` under Oban.Plugins.Cron.
  """
  use Oban.Worker,
    queue: :patrol,
    max_attempts: 3

  require Logger

  alias Crucible.Auth

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    count = Auth.clean_expired_sessions()
    Logger.info("SessionCleaner: deleted #{count} expired sessions")
    :ok
  end
end
