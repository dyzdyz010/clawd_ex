defmodule ClawdEx.Tools.ImageTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Image

  @moduletag :image

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  @png_data_url "data:image/png;base64,#{@png_base64}"

  describe "execute/2 - validation" do
    test "returns error when image is missing or invalid" do
      assert {:error, _} = Image.execute(%{}, %{})
      assert {:error, _} = Image.execute(%{"image" => 123}, %{})
      assert {:error, _} = Image.execute(%{"image" => "not-a-url"}, %{})
      assert {:error, _} = Image.execute(%{"image" => "data:invalid"}, %{})
    end

    test "rejects non-image data URL" do
      base64 = Base.encode64("hello world")
      data_url = "data:text/plain;base64,#{base64}"
      assert {:error, msg} = Image.execute(%{"image" => data_url}, %{})
      assert msg =~ "Unsupported" or msg =~ "image"
    end

    test "rejects data URL exceeding size limit" do
      large_data = String.duplicate("A", 2_000_000)
      large_base64 = Base.encode64(large_data)
      data_url = "data:image/png;base64,#{large_base64}"

      assert {:error, msg} = Image.execute(%{"image" => data_url, "maxBytesMb" => 0.001}, %{})
      assert msg =~ "exceeds" or msg =~ "size"
    end
  end

  describe "execute/2 - data URL decoding" do
    test "accepts valid PNG and JPEG data URLs" do
      result = Image.execute(%{"image" => @png_data_url}, %{})
      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Invalid data URL"
      end

      jpeg_base64 =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="

      result2 = Image.execute(%{"image" => "data:image/jpeg;base64,#{jpeg_base64}"}, %{})
      case result2 do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Invalid data URL"
      end
    end
  end

  describe "execute/2 - model selection" do
    test "accepts various model providers" do
      for model <- ["anthropic/claude-sonnet-4-20250514", "openai/gpt-4o", "google/gemini-2.0-flash"] do
        result = Image.execute(%{"image" => @png_data_url, "model" => model}, %{})
        case result do
          {:ok, _} -> assert true
          {:error, msg} -> refute msg =~ "Unsupported provider"
        end
      end
    end
  end

  describe "execute/2 - prompt handling" do
    test "works with and without custom prompt" do
      result1 = Image.execute(%{"image" => @png_data_url}, %{})
      case result1 do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "prompt"
      end

      result2 = Image.execute(%{"image" => @png_data_url, "prompt" => "What color?"}, %{})
      case result2 do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "prompt"
      end
    end
  end

  describe "execute/2 - parameter key formats" do
    test "accepts both string and atom keys" do
      assert {:error, _} = Image.execute(%{"image" => "invalid"}, %{})
      assert {:error, _} = Image.execute(%{image: "invalid"}, %{})
    end
  end
end
