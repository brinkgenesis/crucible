defmodule Crucible.SecretsAudit do
  @moduledoc """
  Startup audit for secrets hygiene. Checks .env file permissions and
  warns about common misconfigurations. Runs once at application boot.
  """

  require Logger

  @sensitive_patterns ~w(API_KEY TOKEN SECRET PASSWORD PRIVATE_KEY)

  @doc "Run all secrets checks. Called from application.ex start/2."
  def check do
    env_path = env_file_path()

    if File.exists?(env_path) do
      check_file_permissions(env_path)
      check_sensitive_values(env_path)
    end

    :ok
  end

  defp check_file_permissions(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        # Check if world-readable (others have read: octal & 0o004)
        if Bitwise.band(mode, 0o044) != 0 do
          Logger.warning("""
          SecretsAudit: #{path} is group/world-readable (mode: #{Integer.to_string(mode, 8)}).
          Fix with: chmod 600 #{path}
          """)
        end

      {:error, reason} ->
        Logger.debug("SecretsAudit: could not stat #{path}: #{inspect(reason)}")
    end
  end

  defp check_sensitive_values(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: true)

        empty_secrets =
          lines
          |> Enum.reject(&String.starts_with?(&1, "#"))
          |> Enum.filter(fn line ->
            case String.split(line, "=", parts: 2) do
              [key, value] ->
                is_sensitive?(key) and String.trim(value) in ["", "changeme", "xxx", "TODO"]
              _ -> false
            end
          end)

        if empty_secrets != [] do
          keys = Enum.map(empty_secrets, fn line -> line |> String.split("=", parts: 2) |> List.first() end)
          Logger.warning("SecretsAudit: #{length(keys)} sensitive var(s) have placeholder values: #{Enum.join(keys, ", ")}")
        end

      _ -> :ok
    end
  end

  defp is_sensitive?(key) do
    Enum.any?(@sensitive_patterns, &String.contains?(key, &1))
  end

  defp env_file_path do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join(repo_root, ".env")
  end
end
