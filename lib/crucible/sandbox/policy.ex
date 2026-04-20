defmodule Crucible.Sandbox.Policy do
  @moduledoc """
  Sandbox security policy presets.

  Converts named presets into Docker CLI flags for container creation.
  Three presets cover 95% of use cases:

  - `:strict` — no network, /sandbox only, read-only rootfs
  - `:standard` — router endpoint allowed, /sandbox + /tmp, 1GB memory
  - `:permissive` — configurable allowlist, larger resource limits

  ## Usage

      policy = Sandbox.Policy.from_preset(:standard)
      flags = Sandbox.Policy.docker_flags(policy, workspace_path: "/tmp/run-123")
  """

  @type preset :: :strict | :standard | :permissive
  @type t :: %__MODULE__{
          preset: preset,
          network_mode: String.t(),
          allowed_endpoints: [String.t()],
          read_only_rootfs: boolean(),
          memory_limit_mb: non_neg_integer(),
          cpu_quota: non_neg_integer(),
          no_new_privileges: boolean()
        }

  defstruct preset: :standard,
            network_mode: "none",
            allowed_endpoints: [],
            read_only_rootfs: true,
            memory_limit_mb: 512,
            cpu_quota: 50_000,
            no_new_privileges: true

  @doc "Build a policy from a named preset."
  @spec from_preset(preset) :: t
  def from_preset(:strict) do
    %__MODULE__{
      preset: :strict,
      network_mode: "none",
      allowed_endpoints: [],
      read_only_rootfs: true,
      memory_limit_mb: 512,
      cpu_quota: 50_000,
      no_new_privileges: true
    }
  end

  def from_preset(:standard) do
    %__MODULE__{
      preset: :standard,
      network_mode: "bridge",
      allowed_endpoints: extra_endpoints(),
      read_only_rootfs: false,
      memory_limit_mb: 1024,
      cpu_quota: 100_000,
      no_new_privileges: true
    }
  end

  def from_preset(:permissive) do
    %__MODULE__{
      preset: :permissive,
      network_mode: "bridge",
      allowed_endpoints: extra_endpoints(),
      read_only_rootfs: false,
      memory_limit_mb: 2048,
      cpu_quota: 200_000,
      no_new_privileges: true
    }
  end

  # Additional endpoints to allow inside the sandbox. Configure via
  # SANDBOX_NETWORK_ALLOWLIST (comma-separated) or :network_allowlist config.
  defp extra_endpoints do
    case sandbox_config(:network_allowlist, nil) do
      nil -> []
      list when is_list(list) -> list
      str when is_binary(str) -> String.split(str, ",", trim: true)
    end
  end

  @doc "Convert a policy to Docker CLI flags for `docker run`."
  @spec docker_flags(t, keyword()) :: [String.t()]
  def docker_flags(%__MODULE__{} = policy, opts \\ []) do
    workspace_path = Keyword.get(opts, :workspace_path)

    flags =
      [
        "--network=#{policy.network_mode}",
        "--memory=#{policy.memory_limit_mb}m",
        "--cpu-quota=#{policy.cpu_quota}"
      ]
      |> maybe_add(policy.read_only_rootfs, "--read-only")
      |> maybe_add(policy.no_new_privileges, "--security-opt=no-new-privileges")
      |> maybe_add_seccomp()

    # Workspace volume mount
    flags =
      if workspace_path do
        flags ++ ["-v", "#{workspace_path}:/sandbox"]
      else
        flags
      end

    # tmpfs for /tmp when rootfs is read-only
    flags =
      if policy.read_only_rootfs do
        flags ++ ["--tmpfs", "/tmp:rw,noexec,nosuid,size=256m"]
      else
        flags
      end

    flags
  end

  defp maybe_add(flags, true, flag), do: flags ++ [flag]
  defp maybe_add(flags, false, _flag), do: flags

  defp maybe_add_seccomp(flags) do
    seccomp_path = seccomp_profile_path()

    if seccomp_path && File.exists?(seccomp_path) do
      flags ++ ["--security-opt", "seccomp=#{seccomp_path}"]
    else
      flags
    end
  end

  defp seccomp_profile_path do
    priv = :code.priv_dir(:crucible) |> to_string()
    path = Path.join([priv, "sandbox", "seccomp-hardened.json"])
    if File.exists?(path), do: path, else: nil
  end

  @doc """
  Resolve sandbox policy for a tenant.

  Per-tenant overrides were backed by a client_config table that was removed
  from the Crucible v0 schema. All tenants now fall through to the global
  preset. When multi-tenant support returns, reintroduce a per-tenant lookup
  here.
  """
  @spec for_tenant(String.t() | nil) :: t
  def for_tenant(_tenant_id), do: from_preset(global_preset())

  defp global_preset do
    sandbox_config(:policy_preset, :standard)
  end

  defp sandbox_config(key, default) do
    config = Application.get_env(:crucible, :sandbox, [])
    Keyword.get(config, key, default)
  end
end
