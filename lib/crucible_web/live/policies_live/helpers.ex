defmodule CrucibleWeb.PoliciesLive.Helpers do
  @moduledoc """
  Helper functions for the PoliciesLive view.

  Extracts data-transformation and lookup logic from the main LiveView module
  so that event handlers stay focused on socket lifecycle.

  ## Usage

  In `PoliciesLive`, add:

      import CrucibleWeb.PoliciesLive.Helpers

  Then replace private calls with the public versions defined here.
  """

  alias Crucible.Schema.WorkspaceProfile

  @doc """
  Finds a workspace by its ID in a list of workspace profiles.

  Returns the matching `%WorkspaceProfile{}` or `nil` if not found.
  """
  @spec find_workspace([WorkspaceProfile.t()], term()) :: WorkspaceProfile.t() | nil
  def find_workspace(workspaces, id) do
    Enum.find(workspaces, &(&1.id == id))
  end

  @doc """
  Normalizes raw form params into a map suitable for `WorkspaceProfile.policy_changeset/2`.

  Splits the comma-separated `"allowed_models"` string into a list of trimmed,
  non-empty model names and passes through `cost_limit_usd` and
  `approval_threshold` unchanged.

  ## Examples

      iex> normalize_policy_params(%{"allowed_models" => "opus, sonnet", "cost_limit_usd" => "50", "approval_threshold" => "7"})
      %{allowed_models: ["opus", "sonnet"], cost_limit_usd: "50", approval_threshold: "7"}

      iex> normalize_policy_params(%{"allowed_models" => ""})
      %{allowed_models: [], cost_limit_usd: nil, approval_threshold: nil}
  """
  @spec normalize_policy_params(map()) :: map()
  def normalize_policy_params(params) do
    allowed_models =
      (params["allowed_models"] || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      allowed_models: allowed_models,
      cost_limit_usd: params["cost_limit_usd"],
      approval_threshold: params["approval_threshold"]
    }
  end
end
