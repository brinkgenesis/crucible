defmodule Crucible.Sandbox.LocalProviderTest do
  use ExUnit.Case, async: true

  alias Crucible.Sandbox.LocalProvider

  describe "start_sandbox/1" do
    test "returns a unique sandbox ID" do
      {:ok, id1} = LocalProvider.start_sandbox(%{})
      {:ok, id2} = LocalProvider.start_sandbox(%{})
      assert is_binary(id1)
      assert is_binary(id2)
      assert id1 != id2
      assert String.starts_with?(id1, "local-")
    end
  end

  describe "stop_sandbox/1" do
    test "always returns :ok" do
      {:ok, id} = LocalProvider.start_sandbox(%{})
      assert :ok = LocalProvider.stop_sandbox(id)
    end
  end

  describe "exec/3" do
    test "executes command and returns output" do
      {:ok, id} = LocalProvider.start_sandbox(%{})
      assert {:ok, output} = LocalProvider.exec(id, "echo hello")
      assert String.trim(output) == "hello"
    end

    test "returns error on non-zero exit code" do
      {:ok, id} = LocalProvider.start_sandbox(%{})
      assert {:error, {:exit_code, _, _}} = LocalProvider.exec(id, "exit 42")
    end

    test "respects timeout" do
      {:ok, id} = LocalProvider.start_sandbox(%{})
      assert {:error, :timeout} = LocalProvider.exec(id, "sleep 10", timeout_ms: 100)
    end
  end

  describe "status/1" do
    test "always returns :running" do
      {:ok, id} = LocalProvider.start_sandbox(%{})
      assert :running = LocalProvider.status(id)
    end
  end
end
