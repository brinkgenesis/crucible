defmodule Crucible.Secrets.Provider do
  @moduledoc """
  Behaviour for secrets providers.

  Implementations fetch secrets from a backend (env vars, AWS Secrets Manager, etc.)
  and return them as a key-value map.
  """

  @callback fetch_all(keys :: [String.t()]) ::
              {:ok, %{String.t() => String.t() | nil}} | {:error, term()}
end
