defmodule Crucible.KnowledgeLoopTest do
  use ExUnit.Case, async: true

  alias Crucible.SelfImprovement

  @moduletag :tmp_dir

  describe "compute_knowledge_loop/2" do
    test "returns all stalled when vault dirs don't exist", %{tmp_dir: tmp_dir} do
      result = SelfImprovement.compute_knowledge_loop(tmp_dir, 24)
      assert result.learn_count == 0
      assert result.create_count == 0
      assert result.share_count == 0
      assert result.stalled_stages == [:learn, :create, :share]
      assert result.loop_completeness == 0.0
    end

    test "counts recent notes in each category", %{tmp_dir: tmp_dir} do
      # Create vault structure with recent files
      vault = Path.join(tmp_dir, "memory")

      for dir <- ["lessons", "observations", "decisions", "handoffs"] do
        File.mkdir_p!(Path.join(vault, dir))
      end

      # Create lesson files
      File.write!(Path.join(vault, "lessons/lesson-1.md"), "# Lesson 1")
      File.write!(Path.join(vault, "lessons/lesson-2.md"), "# Lesson 2")
      File.write!(Path.join(vault, "observations/obs-1.md"), "# Obs 1")

      # Create decision files
      File.write!(Path.join(vault, "decisions/dec-1.md"), "# Decision 1")

      # Create handoff files
      File.write!(Path.join(vault, "handoffs/handoff-1.md"), "# Handoff 1")
      File.write!(Path.join(vault, "handoffs/handoff-2.md"), "# Handoff 2")

      result = SelfImprovement.compute_knowledge_loop(tmp_dir, 24)
      assert result.learn_count == 3
      assert result.create_count == 1
      assert result.share_count == 2
      assert result.stalled_stages == []
      assert result.loop_completeness == 1.0
    end

    test "detects stalled learn stage", %{tmp_dir: tmp_dir} do
      vault = Path.join(tmp_dir, "memory")
      File.mkdir_p!(Path.join(vault, "decisions"))
      File.mkdir_p!(Path.join(vault, "handoffs"))
      File.write!(Path.join(vault, "decisions/dec-1.md"), "# Decision")
      File.write!(Path.join(vault, "handoffs/handoff-1.md"), "# Handoff")

      result = SelfImprovement.compute_knowledge_loop(tmp_dir, 24)
      assert :learn in result.stalled_stages
      refute :create in result.stalled_stages
      refute :share in result.stalled_stages
      assert result.loop_completeness == Float.round(2 / 3, 2)
    end

    test "ignores non-md files", %{tmp_dir: tmp_dir} do
      vault = Path.join(tmp_dir, "memory")
      File.mkdir_p!(Path.join(vault, "lessons"))
      File.write!(Path.join(vault, "lessons/lesson-1.md"), "# Lesson")
      File.write!(Path.join(vault, "lessons/notes.txt"), "not a note")

      result = SelfImprovement.compute_knowledge_loop(tmp_dir, 24)
      assert result.learn_count == 1
    end

    test "ignores old files outside lookback window", %{tmp_dir: tmp_dir} do
      vault = Path.join(tmp_dir, "memory")
      File.mkdir_p!(Path.join(vault, "lessons"))

      path = Path.join(vault, "lessons/old-lesson.md")
      File.write!(path, "# Old Lesson")

      # Set mtime to 2 days ago (outside 1-hour window)
      old_time = System.os_time(:second) - 2 * 86400
      File.touch!(path, old_time)

      result = SelfImprovement.compute_knowledge_loop(tmp_dir, 1)
      assert result.learn_count == 0
      assert :learn in result.stalled_stages
    end
  end
end
