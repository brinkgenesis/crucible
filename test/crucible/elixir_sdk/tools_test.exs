defmodule Crucible.ElixirSdk.ToolsTest do
  use ExUnit.Case, async: true

  alias Crucible.ElixirSdk.Tools

  setup do
    tmp =
      Path.join([System.tmp_dir!(), "crucible-tool-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, ctx: %{cwd: tmp, permission_mode: :default}}
  end

  describe "Read" do
    test "returns numbered lines", %{tmp: tmp, ctx: ctx} do
      path = Path.join(tmp, "sample.txt")
      File.write!(path, "alpha\nbeta\ngamma")

      assert {:ok, output} = Tools.Read.run(%{"file_path" => "sample.txt"}, ctx)
      assert output =~ "alpha"
      assert output =~ "beta"
      assert output =~ "gamma"
      # numbering prefixes each line
      assert output =~ ~r/\s1\s+alpha/
    end

    test "resolves absolute paths", %{tmp: tmp, ctx: ctx} do
      path = Path.join(tmp, "x.txt")
      File.write!(path, "hello")
      assert {:ok, output} = Tools.Read.run(%{"file_path" => path}, ctx)
      assert output =~ "hello"
    end

    test "returns error for missing files", %{ctx: ctx} do
      assert {:error, _} = Tools.Read.run(%{"file_path" => "nope.txt"}, ctx)
    end
  end

  describe "Write" do
    test "creates file and parent dirs", %{tmp: tmp, ctx: ctx} do
      assert {:ok, _} =
               Tools.Write.run(%{"file_path" => "a/b/c.txt", "content" => "xyz"}, ctx)

      assert File.read!(Path.join(tmp, "a/b/c.txt")) == "xyz"
    end

    test "plan mode does not write", %{tmp: tmp} do
      ctx = %{cwd: tmp, permission_mode: :plan}
      assert {:ok, msg} = Tools.Write.run(%{"file_path" => "x.txt", "content" => "xyz"}, ctx)
      assert msg =~ "plan mode"
      refute File.exists?(Path.join(tmp, "x.txt"))
    end
  end

  describe "Edit" do
    test "single-occurrence replace", %{tmp: tmp, ctx: ctx} do
      path = Path.join(tmp, "a.txt")
      File.write!(path, "foo bar baz")

      assert {:ok, _} =
               Tools.Edit.run(
                 %{"file_path" => "a.txt", "old_string" => "bar", "new_string" => "BAR"},
                 ctx
               )

      assert File.read!(path) == "foo BAR baz"
    end

    test "ambiguous match refuses", %{tmp: tmp, ctx: ctx} do
      path = Path.join(tmp, "a.txt")
      File.write!(path, "x x x")

      assert {:error, msg} =
               Tools.Edit.run(
                 %{"file_path" => "a.txt", "old_string" => "x", "new_string" => "Y"},
                 ctx
               )

      assert msg =~ "3 times"
    end

    test "replace_all forces ambiguous replace", %{tmp: tmp, ctx: ctx} do
      path = Path.join(tmp, "a.txt")
      File.write!(path, "x x x")

      assert {:ok, _} =
               Tools.Edit.run(
                 %{
                   "file_path" => "a.txt",
                   "old_string" => "x",
                   "new_string" => "Y",
                   "replace_all" => true
                 },
                 ctx
               )

      assert File.read!(path) == "Y Y Y"
    end
  end

  describe "Bash" do
    test "runs command and captures stdout", %{ctx: ctx} do
      assert {:ok, out} = Tools.Bash.run(%{"command" => "echo hello"}, ctx)
      assert out =~ "hello"
    end

    test "captures non-zero exit", %{ctx: ctx} do
      assert {:ok, out} =
               Tools.Bash.run(%{"command" => "exit 7"}, ctx)

      assert out =~ "[exit 7]"
    end

    test "times out", %{ctx: ctx} do
      assert {:error, msg} =
               Tools.Bash.run(%{"command" => "sleep 3", "timeout" => 100}, ctx)

      assert msg =~ "timed out"
    end

    test "plan mode does not execute", %{tmp: tmp} do
      ctx = %{cwd: tmp, permission_mode: :plan}
      marker = Path.join(tmp, "marker.txt")
      assert {:ok, _} = Tools.Bash.run(%{"command" => "touch #{marker}"}, ctx)
      refute File.exists?(marker)
    end
  end

  describe "Glob" do
    test "finds files by pattern", %{tmp: tmp, ctx: ctx} do
      for name <- ~w(a.ex b.ex c.js), do: File.write!(Path.join(tmp, name), "")

      assert {:ok, out} = Tools.Glob.run(%{"pattern" => "*.ex"}, ctx)
      assert out =~ "a.ex"
      assert out =~ "b.ex"
      refute out =~ "c.js"
    end

    test "no matches returns explicit message", %{ctx: ctx} do
      assert {:ok, "No matches."} = Tools.Glob.run(%{"pattern" => "*.nope"}, ctx)
    end
  end

  describe "Grep" do
    setup %{tmp: tmp} do
      File.write!(Path.join(tmp, "a.ex"), "defmodule A do\n  @needle true\nend\n")
      File.write!(Path.join(tmp, "b.ex"), "defmodule B do\nend\n")
      :ok
    end

    test "files_with_matches mode returns paths", %{ctx: ctx} do
      assert {:ok, out} = Tools.Grep.run(%{"pattern" => "@needle"}, ctx)
      assert out =~ "a.ex"
      refute out =~ "b.ex"
    end
  end
end
