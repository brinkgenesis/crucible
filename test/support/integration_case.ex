defmodule Crucible.IntegrationCase do
  @moduledoc """
  Base case template for integration tests.
  Sets up sandbox, starts application if needed.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      @moduletag :integration

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Crucible.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(Crucible.Repo, {:shared, self()})
        :ok
      end
    end
  end
end
