defmodule Crucible.Workspace.LocalBackendTest do
  use ExUnit.Case, async: true

  alias Crucible.Workspace.LocalBackend

  @tmp_dir System.tmp_dir!()

  setup do
    base = Path.join(@tmp_dir, "workspace_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  describe "read/2" do
    test "reads file content", %{base: base} do
      path = Path.join(base, "test.txt")
      File.write!(path, "hello world")

      assert {:ok, "hello world"} = LocalBackend.read("test.txt", base_dir: base)
    end

    test "returns error for missing file", %{base: base} do
      assert {:error, :enoent} = LocalBackend.read("missing.txt", base_dir: base)
    end

    test "reads without base_dir" do
      tmp = Path.join(@tmp_dir, "direct_read_#{:rand.uniform(100_000)}.txt")
      File.write!(tmp, "direct")

      assert {:ok, "direct"} = LocalBackend.read(tmp)
      File.rm!(tmp)
    end
  end

  describe "write/3" do
    test "writes content to file", %{base: base} do
      assert :ok = LocalBackend.write("output.txt", "test content", base_dir: base)
      assert File.read!(Path.join(base, "output.txt")) == "test content"
    end

    test "creates nested directories", %{base: base} do
      assert :ok = LocalBackend.write("a/b/c/deep.txt", "deep", base_dir: base)
      assert File.read!(Path.join(base, "a/b/c/deep.txt")) == "deep"
    end

    test "overwrites existing file", %{base: base} do
      LocalBackend.write("overwrite.txt", "v1", base_dir: base)
      LocalBackend.write("overwrite.txt", "v2", base_dir: base)

      assert {:ok, "v2"} = LocalBackend.read("overwrite.txt", base_dir: base)
    end
  end

  describe "exec/2 — string mode (legacy sh -c)" do
    test "executes command and returns output", %{base: base} do
      assert {:ok, output} = LocalBackend.exec("echo hello", base_dir: base)
      assert String.trim(output) == "hello"
    end

    test "returns error for failing command", %{base: base} do
      assert {:error, {:exit_code, _, _}} = LocalBackend.exec("exit 1", base_dir: base)
    end

    test "respects timeout" do
      # 100ms timeout for a 10s sleep should timeout
      assert {:error, :timeout} = LocalBackend.exec("sleep 10", timeout_ms: 100)
    end

    test "captures stderr in output", %{base: base} do
      assert {:ok, output} = LocalBackend.exec("echo err >&2", base_dir: base)
      assert String.trim(output) == "err"
    end
  end

  describe "exec/2 — structured args mode (no shell)" do
    test "succeeds with pre-split args", %{base: base} do
      assert {:ok, output} = LocalBackend.exec({"echo", ["hello"]}, base_dir: base)
      assert String.trim(output) == "hello"
    end

    test "does NOT shell-interpret semicolon injection" do
      # In sh -c mode "echo a; echo b" would print two lines.
      # In args mode it is passed as a literal argument to echo.
      assert {:ok, output} = LocalBackend.exec({"echo", ["a; echo b"]})
      assert String.trim(output) == "a; echo b"
    end

    test "does NOT shell-interpret command substitution" do
      # $(uname) would be expanded by sh -c. In args mode it's a literal string.
      assert {:ok, output} = LocalBackend.exec({"echo", ["$(uname)"]})
      assert String.trim(output) == "$(uname)"
    end

    test "returns error for failing command in args mode" do
      assert {:error, {:exit_code, 1, _}} = LocalBackend.exec({"false", []})
    end

    test "respects timeout in args mode" do
      assert {:error, :timeout} = LocalBackend.exec({"sleep", ["10"]}, timeout_ms: 100)
    end

    test "uses base_dir as working directory", %{base: base} do
      # pwd prints the physical cwd. On macOS /tmp is a symlink to
      # /private/var/…, so pwd may return a path with or without the
      # /private prefix. We check that the output ends with the
      # canonical suffix of base to handle both representations.
      assert {:ok, output} = LocalBackend.exec({"pwd", []}, base_dir: base)
      actual = String.trim(output)
      # Strip a /private prefix if present on either side for comparison.
      strip_private = fn p -> String.replace_prefix(p, "/private", "") end
      assert strip_private.(actual) == strip_private.(base)
    end
  end

  describe "list/2" do
    test "lists directory entries", %{base: base} do
      File.write!(Path.join(base, "a.txt"), "")
      File.write!(Path.join(base, "b.txt"), "")

      assert {:ok, entries} = LocalBackend.list(".", base_dir: base)
      assert "a.txt" in entries
      assert "b.txt" in entries
    end

    test "returns error for missing directory", %{base: base} do
      assert {:error, :enoent} = LocalBackend.list("nonexistent", base_dir: base)
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{base: base} do
      File.write!(Path.join(base, "exists.txt"), "")
      assert LocalBackend.exists?("exists.txt", base_dir: base)
    end

    test "returns false for missing file", %{base: base} do
      refute LocalBackend.exists?("nope.txt", base_dir: base)
    end
  end

  describe "delete/2" do
    test "deletes a file", %{base: base} do
      File.write!(Path.join(base, "delete_me.txt"), "")
      assert :ok = LocalBackend.delete("delete_me.txt", base_dir: base)
      refute File.exists?(Path.join(base, "delete_me.txt"))
    end

    test "returns error for missing file", %{base: base} do
      assert {:error, :enoent} = LocalBackend.delete("nope.txt", base_dir: base)
    end
  end

  describe "mkdir_p/2" do
    test "creates nested directories", %{base: base} do
      assert :ok = LocalBackend.mkdir_p("x/y/z", base_dir: base)
      assert File.dir?(Path.join(base, "x/y/z"))
    end
  end

  describe "path traversal protection" do
    test "blocks ../etc/passwd escape", %{base: base} do
      assert {:error, :path_traversal} = LocalBackend.read("../../etc/passwd", base_dir: base)
    end

    test "absolute path is joined safely by Path.join (Elixir strips leading /)", %{base: base} do
      # In Elixir, Path.join(base, "/etc/passwd") => "#{base}/etc/passwd" — safe
      # This file won't exist, so we get :enoent, but NOT :path_traversal
      assert {:error, :enoent} = LocalBackend.read("/etc/passwd", base_dir: base)
    end

    test "blocks nested traversal", %{base: base} do
      assert {:error, :path_traversal} =
               LocalBackend.read("a/b/../../../../etc/passwd", base_dir: base)
    end

    test "allows normal nested paths", %{base: base} do
      File.mkdir_p!(Path.join(base, "sub"))
      File.write!(Path.join(base, "sub/file.txt"), "ok")

      assert {:ok, "ok"} = LocalBackend.read("sub/file.txt", base_dir: base)
    end

    test "allows path to base itself", %{base: base} do
      # Listing the base directory should work
      assert {:ok, _entries} = LocalBackend.list(".", base_dir: base)
    end

    test "blocks traversal on write", %{base: base} do
      assert {:error, :path_traversal} =
               LocalBackend.write("../../escape.txt", "bad", base_dir: base)
    end

    test "blocks traversal on delete", %{base: base} do
      assert {:error, :path_traversal} =
               LocalBackend.delete("../../escape.txt", base_dir: base)
    end

    test "blocks traversal on exists?", %{base: base} do
      refute LocalBackend.exists?("../../etc/passwd", base_dir: base)
    end

    test "no protection when base_dir is nil" do
      # Without base_dir, path is used as-is (caller responsibility)
      assert {:error, :enoent} = LocalBackend.read("/nonexistent/path/file.txt")
    end
  end
end
