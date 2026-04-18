defmodule Crucible.ElixirSdk.Tool do
  @moduledoc """
  Behaviour for tools executable by the Elixir SDK.

  A tool is a module that exposes:

    * `schema/0` — the JSON schema sent to Anthropic so the model knows the
      tool's name, description, and input shape.
    * `run/2` — executes the tool given the input map and a context
      (`%{cwd: String.t(), permission_mode: atom()}`).

  Implementations should be pure and deterministic where possible. Anything
  touching the filesystem should resolve paths relative to `ctx.cwd` unless
  an absolute path is given. Side-effectful tools (Bash, Write, Edit) should
  respect the permission mode.
  """

  @type schema :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map()
        }

  @type ctx :: %{cwd: String.t(), permission_mode: atom()}

  @type result :: {:ok, String.t() | iodata()} | {:error, term()}

  @callback schema() :: schema()
  @callback run(input :: map(), ctx :: ctx()) :: result()
end
