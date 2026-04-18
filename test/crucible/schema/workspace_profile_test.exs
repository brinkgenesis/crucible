defmodule Crucible.Schema.WorkspaceProfileTest do
  use ExUnit.Case, async: true

  alias Crucible.Schema.WorkspaceProfile

  @valid_attrs %{
    name: "Infra",
    slug: "infra",
    repo_path: "/workspace/example"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, @valid_attrs)
      assert cs.valid?
    end

    test "invalid without name" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.delete(@valid_attrs, :name))
      refute cs.valid?
      assert cs.errors[:name]
    end

    test "invalid without slug" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.delete(@valid_attrs, :slug))
      refute cs.valid?
      assert cs.errors[:slug]
    end

    test "invalid without repo_path" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.delete(@valid_attrs, :repo_path))
      refute cs.valid?
      assert cs.errors[:repo_path]
    end

    test "validates slug format — lowercase alphanumeric with hyphens" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, %{@valid_attrs | slug: "Valid-Slug"})
      refute cs.valid?
      assert cs.errors[:slug]
    end

    test "accepts valid slug formats" do
      for slug <- ~w(my-project my_project project123 a) do
        cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, %{@valid_attrs | slug: slug})
        assert cs.valid?, "expected slug '#{slug}' to be valid"
      end
    end

    test "validates name length" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, %{@valid_attrs | name: ""})
      refute cs.valid?
      assert cs.errors[:name]
    end

    test "validates cost_limit_usd is non-negative" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.put(@valid_attrs, :cost_limit_usd, -5))
      refute cs.valid?
      assert cs.errors[:cost_limit_usd]
    end

    test "validates approval_threshold range" do
      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.put(@valid_attrs, :approval_threshold, 0))
      refute cs.valid?

      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.put(@valid_attrs, :approval_threshold, 11))
      refute cs.valid?

      cs = WorkspaceProfile.changeset(%WorkspaceProfile{}, Map.put(@valid_attrs, :approval_threshold, 5))
      assert cs.valid?
    end

    test "defaults default_workflow to coding-sprint" do
      profile = %WorkspaceProfile{}
      assert profile.default_workflow == "coding-sprint"
    end
  end
end
