defmodule Crucible.TsDashboard do
  @moduledoc false
  # Deprecated — use Crucible.ApiServer instead.
  # This module delegates all calls for backwards compatibility.

  defdelegate fetch(path), to: Crucible.ApiServer
  defdelegate post(path, body \\ %{}), to: Crucible.ApiServer
  defdelegate post_json(path, body \\ %{}, opts \\ []), to: Crucible.ApiServer
end
