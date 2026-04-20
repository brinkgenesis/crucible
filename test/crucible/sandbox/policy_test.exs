defmodule Crucible.Sandbox.PolicyTest do
  use ExUnit.Case, async: true

  alias Crucible.Sandbox.Policy

  describe "from_preset/1" do
    test "strict preset has no network and read-only rootfs" do
      policy = Policy.from_preset(:strict)
      assert policy.network_mode == "none"
      assert policy.read_only_rootfs == true
      assert policy.no_new_privileges == true
      assert policy.allowed_endpoints == []
      assert policy.memory_limit_mb == 512
    end

    test "standard preset has bridge network with empty default allowlist" do
      policy = Policy.from_preset(:standard)
      assert policy.network_mode == "bridge"
      assert policy.read_only_rootfs == false
      assert policy.no_new_privileges == true
      assert policy.memory_limit_mb == 1024
      assert policy.allowed_endpoints == []
    end

    test "standard preset includes endpoints from :network_allowlist config" do
      original = Application.get_env(:crucible, :sandbox, [])

      try do
        Application.put_env(
          :crucible,
          :sandbox,
          Keyword.put(original, :network_allowlist, ["api.anthropic.com:443"])
        )

        policy = Policy.from_preset(:standard)
        assert "api.anthropic.com:443" in policy.allowed_endpoints
      after
        Application.put_env(:crucible, :sandbox, original)
      end
    end

    test "permissive preset has larger resource limits" do
      policy = Policy.from_preset(:permissive)
      assert policy.network_mode == "bridge"
      assert policy.memory_limit_mb == 2048
      assert policy.cpu_quota == 200_000
    end
  end

  describe "docker_flags/2" do
    test "strict preset generates correct flags" do
      policy = Policy.from_preset(:strict)
      flags = Policy.docker_flags(policy, workspace_path: "/tmp/test-ws")

      assert "--network=none" in flags
      assert "--read-only" in flags
      assert "--security-opt=no-new-privileges" in flags
      assert "--memory=512m" in flags
      assert Enum.any?(flags, &String.contains?(&1, "/tmp/test-ws:/sandbox"))
      assert Enum.any?(flags, &String.starts_with?(&1, "--tmpfs"))
    end

    test "standard preset does not include --read-only" do
      policy = Policy.from_preset(:standard)
      flags = Policy.docker_flags(policy)

      assert "--network=bridge" in flags
      assert "--security-opt=no-new-privileges" in flags
      refute "--read-only" in flags
    end

    test "workspace path is mounted at /sandbox" do
      policy = Policy.from_preset(:standard)
      flags = Policy.docker_flags(policy, workspace_path: "/home/user/project")

      volume_flag_idx = Enum.find_index(flags, &(&1 == "-v"))
      assert volume_flag_idx != nil
      assert Enum.at(flags, volume_flag_idx + 1) == "/home/user/project:/sandbox"
    end

    test "no volume mount when workspace_path not provided" do
      policy = Policy.from_preset(:standard)
      flags = Policy.docker_flags(policy)

      refute "-v" in flags
    end
  end
end
