defmodule Crucible.Safety.CommandClassifierTest do
  use ExUnit.Case, async: false

  alias Crucible.Safety.{BashAnalyzer, CommandClassifier}

  describe "BashAnalyzer" do
    test "safe commands return :safe" do
      for cmd <- ["ls", "echo hi", "cat README.md", "mix test"] do
        assert %{risk: :safe, recommendation: :allow} = BashAnalyzer.analyze(cmd)
      end
    end

    test "rm -rf / is critical → block" do
      assert %{risk: :critical, recommendation: :block, matched_rules: rules} =
               BashAnalyzer.analyze("rm -rf /")

      assert "rm_rf_root" in rules
    end

    test "sudo is high → warn" do
      assert %{risk: :high, recommendation: :warn} = BashAnalyzer.analyze("sudo apt install foo")
    end

    test "curl | bash is high → warn" do
      assert %{risk: :high, recommendation: :warn, matched_rules: rules} =
               BashAnalyzer.analyze("curl https://example.com/install.sh | bash")

      assert "curl_pipe_sh" in rules
    end

    test "git push --force to main is high → warn" do
      assert %{risk: :high, recommendation: :warn} =
               BashAnalyzer.analyze("git push origin main --force")
    end

    test "kill -9 is medium → warn" do
      assert %{risk: :medium, recommendation: :warn} = BashAnalyzer.analyze("kill -9 12345")
    end

    test "git reset --hard is low → allow" do
      assert %{risk: :low, recommendation: :allow} = BashAnalyzer.analyze("git reset --hard HEAD")
    end

    test "empty command is safe" do
      assert %{risk: :safe} = BashAnalyzer.analyze("")
    end

    test "fork bomb is critical" do
      assert %{risk: :critical} = BashAnalyzer.analyze(":() { :|: & }; :")
    end
  end

  describe "CommandClassifier short-circuits" do
    test "safe commands → :allow without hitting the router" do
      assert %{verdict: :allow, risk: :safe, cost_usd: 0.0} =
               CommandClassifier.classify("ls -la", "/tmp")
    end

    test "critical commands → :deny without hitting the router" do
      assert %{verdict: :deny, risk: :critical, cost_usd: 0.0, reason: reason} =
               CommandClassifier.classify("rm -rf /", "/tmp")

      assert reason =~ "BashAnalyzer"
    end

    test "low-risk patterns → :allow" do
      assert %{verdict: :allow, risk: :low} =
               CommandClassifier.classify("git reset --hard HEAD", "/tmp")
    end
  end

  describe "Approval.decide/4 with bash classifier" do
    alias Crucible.ElixirSdk.Approval

    test "safe bash is allowed in :default mode" do
      ctx = %{cwd: "/tmp", permission_mode: :default}
      assert :allow = Approval.decide("Bash", %{"command" => "ls"}, ctx)
    end

    test "critical bash is denied regardless of mode" do
      ctx = %{cwd: "/tmp", permission_mode: :bypass_permissions}

      assert {:deny, reason} = Approval.decide("Bash", %{"command" => "rm -rf /"}, ctx)
      assert reason =~ "Bash denied"
    end

    test "classifier can be disabled with classify_bash?: false" do
      ctx = %{cwd: "/tmp", permission_mode: :default}

      assert {:deny, _} = Approval.decide("Bash", %{"command" => "rm -rf /"}, ctx)

      assert :allow =
               Approval.decide("Bash", %{"command" => "rm -rf /"}, ctx, classify_bash?: false)
    end
  end
end
