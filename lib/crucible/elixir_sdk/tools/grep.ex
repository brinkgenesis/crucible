defmodule Crucible.ElixirSdk.Tools.Grep do
  @moduledoc """
  Content search via ripgrep.

  Prefers the system `rg` binary. Falls back to a pure-Elixir walk if rg
  is not available (slower; not recommended for large trees).
  """

  @behaviour Crucible.ElixirSdk.Tool

  @max_output_bytes 20_000

  @impl true
  def schema do
    %{
      name: "Grep",
      description: """
      Search file contents with a regular expression. Defaults to returning
      file paths with matches. Set `output_mode` to `"content"` for matching
      lines with line numbers.
      """,
      input_schema: %{
        type: "object",
        required: ["pattern"],
        properties: %{
          pattern: %{type: "string", description: "Regular expression (PCRE-ish)."},
          path: %{type: "string", description: "Directory or file to search (default: workspace)."},
          glob: %{type: "string", description: "Glob filter (e.g. *.ex, *.{ts,tsx})."},
          output_mode: %{
            type: "string",
            enum: ["files_with_matches", "content", "count"],
            default: "files_with_matches"
          },
          case_insensitive: %{type: "boolean", default: false},
          max_results: %{type: "integer", default: 200}
        }
      }
    }
  end

  @impl true
  def run(%{"pattern" => pattern} = input, ctx) do
    args = build_args(input)

    search_path =
      case Map.get(input, "path") do
        nil -> ctx.cwd
        p -> if Path.type(p) == :absolute, do: p, else: Path.join(ctx.cwd, p)
      end

    case System.find_executable("rg") do
      nil ->
        fallback(pattern, search_path, input)

      rg ->
        {output, _status} =
          System.cmd(rg, args ++ [pattern, search_path], stderr_to_stdout: true, cd: ctx.cwd)

        {:ok, truncate(output, @max_output_bytes)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "Grep requires `pattern` string."}

  defp build_args(input) do
    base = ["--color=never"]

    mode_args =
      case Map.get(input, "output_mode", "files_with_matches") do
        "files_with_matches" -> ["--files-with-matches"]
        "count" -> ["--count"]
        "content" -> ["--line-number"]
        _ -> ["--files-with-matches"]
      end

    glob_args =
      case Map.get(input, "glob") do
        nil -> []
        g when is_binary(g) -> ["--glob", g]
      end

    case_args =
      if Map.get(input, "case_insensitive", false), do: ["-i"], else: []

    limit =
      case Map.get(input, "max_results", 200) do
        n when is_integer(n) and n > 0 -> ["--max-count", Integer.to_string(n)]
        _ -> []
      end

    base ++ mode_args ++ glob_args ++ case_args ++ limit
  end

  defp fallback(pattern, path, _input) do
    regex = Regex.compile!(pattern, "u")

    matches =
      path
      |> Path.wildcard("**/*", match_dot: false)
      |> Enum.filter(&File.regular?/1)
      |> Enum.take(1000)
      |> Enum.filter(fn file ->
        case File.read(file) do
          {:ok, c} -> Regex.match?(regex, c)
          _ -> false
        end
      end)
      |> Enum.take(200)

    {:ok, Enum.join(matches, "\n")}
  end

  defp truncate(s, max) when byte_size(s) > max,
    do: binary_part(s, 0, max) <> "\n… (truncated)"

  defp truncate(s, _), do: s
end
