defmodule Crucible.Safety.BashAnalyzer do
  @moduledoc """
  Pattern-based bash risk analyzer.

  Assigns a risk level (`:critical`, `:high`, `:medium`, `:low`, `:safe`)
  by matching the command string against well-known dangerous patterns.
  Deliberately simpler than a full AST parser — we cover the signatures
  that matter for agent safety, and let the ML classifier handle nuance.

  Recommendations:
    * `:block` — never run (critical patterns like `rm -rf /`)
    * `:warn`  — run through ML classifier for context-aware verdict
    * `:allow` — harmless

  Returns a `%{risk, recommendation, matched_rules}` report. Callers
  (Approval, ElixirSdk.Query, inspection UIs) decide what to do.
  """

  @type risk :: :critical | :high | :medium | :low | :safe
  @type recommendation :: :block | :warn | :allow

  @type report :: %{
          risk: risk(),
          recommendation: recommendation(),
          matched_rules: [String.t()]
        }

  @critical [
    {"rm_rf_root", ~r/\brm\s+(-[rRf]+|-[-a-z]+\s+)*\/(\s|$)/},
    {"rm_rf_home", ~r/\brm\s+(-[rRf]+|-[-a-z]+\s+)*(~|\$HOME)(\s|$)/},
    {"mkfs", ~r/\bmkfs\b/},
    {"dd_disk", ~r/\bdd\s+.*of=\/dev\//},
    {"fork_bomb", ~r/:\s*\(\s*\)\s*\{.*:\|:.*\}\s*;/}
  ]

  @high [
    {"rm_rf_deep", ~r/\brm\s+(-[rRf]+|-[-a-z]+\s+)*(\.\.|\*)(\s|$)/},
    {"chmod_777", ~r/\bchmod\s+-?R?\s*7(77|55)\b/},
    {"sudo", ~r/\bsudo\b/},
    {"curl_pipe_sh", ~r/\bcurl\b.*\|\s*(ba)?sh\b/},
    {"wget_pipe_sh", ~r/\bwget\b.*\|\s*(ba)?sh\b/},
    {"eval_variable", ~r/\beval\s+["']?\$/},
    {"git_force_push", ~r/git\s+push\s+.*--force\b/},
    {"git_push_master_force", ~r/git\s+push\s+.*--force.*\b(main|master)\b/}
  ]

  @medium [
    {"rm_any", ~r/\brm\s+-[rRf]/},
    {"mv_root_dirs", ~r/\bmv\s+\/(usr|etc|bin|sbin|lib|var|opt)\b/},
    {"kill_pattern", ~r/\bkill\s+-(9|KILL)\b/},
    {"chown_root", ~r/\bchown\s+-?R?\s*root\b/},
    {"curl_with_exec", ~r/\bcurl\b.*\|(tee|bash|sh|python|node)\b/},
    {"network_exec", ~r/\b(nc|netcat|ncat)\b.*-e\b/}
  ]

  @low [
    {"git_reset_hard", ~r/\bgit\s+reset\s+--hard\b/},
    {"git_clean", ~r/\bgit\s+clean\s+-fd?/},
    {"npm_uninstall", ~r/\bnpm\s+uninstall\s+-g\b/}
  ]

  @doc "Analyze a bash command string."
  @spec analyze(String.t()) :: report()
  def analyze(command) when is_binary(command) do
    normalised = String.trim(command)

    cond do
      normalised == "" ->
        safe_report()

      rules = matches(@critical, normalised) ->
        %{risk: :critical, recommendation: :block, matched_rules: rules}

      rules = matches(@high, normalised) ->
        %{risk: :high, recommendation: :warn, matched_rules: rules}

      rules = matches(@medium, normalised) ->
        %{risk: :medium, recommendation: :warn, matched_rules: rules}

      rules = matches(@low, normalised) ->
        %{risk: :low, recommendation: :allow, matched_rules: rules}

      true ->
        safe_report()
    end
  end

  def analyze(_), do: safe_report()

  # ── internals ──────────────────────────────────────────────────────────

  defp matches(rules, command) do
    found =
      rules
      |> Enum.filter(fn {_name, regex} -> Regex.match?(regex, command) end)
      |> Enum.map(fn {name, _regex} -> name end)

    if found == [], do: nil, else: found
  end

  defp safe_report, do: %{risk: :safe, recommendation: :allow, matched_rules: []}
end
