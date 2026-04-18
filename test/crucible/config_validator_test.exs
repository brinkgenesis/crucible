defmodule Crucible.ConfigValidatorTest do
  use ExUnit.Case, async: true

  alias Crucible.ConfigValidator

  describe "validate!/0" do
    test "passes in non-prod (default config_env is :dev)" do
      assert ConfigValidator.validate!() == :ok
    end
  end
end
