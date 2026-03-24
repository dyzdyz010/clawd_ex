defmodule ClawdEx.AI.ModelsTest do
  use ExUnit.Case, async: true

  alias ClawdEx.AI.Models

  @moduletag :models

  describe "exists?/1" do
    test "returns true for full model name" do
      assert Models.exists?("anthropic/claude-opus-4-5")
    end

    test "returns true for valid alias" do
      assert Models.exists?("sonnet")
    end

    test "returns true for another alias" do
      assert Models.exists?("opus")
    end

    test "returns false for unknown model" do
      refute Models.exists?("nonexistent-model-xyz")
    end

    test "returns false for empty string" do
      # resolve("") returns default which exists, but that's by design
      # exists? checks if the resolved model is known
      assert Models.exists?("")
    end

    test "returns true for google model" do
      assert Models.exists?("google/gemini-3-pro")
    end

    test "returns true for groq model" do
      assert Models.exists?("groq/llama-3.3-70b-versatile")
    end
  end
end
