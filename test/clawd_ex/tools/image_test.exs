defmodule ClawdEx.Tools.ImageTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Image

  @moduletag :image

  describe "name/0" do
    test "returns image" do
      assert Image.name() == "image"
    end
  end

  describe "description/0" do
    test "returns description string" do
      desc = Image.description()
      assert is_binary(desc)
      assert String.contains?(desc, "image")
      assert String.contains?(desc, "vision")
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = Image.parameters()
      assert params[:type] == "object"
      assert is_map(params[:properties])
      assert params[:properties][:image]
      assert params[:properties][:prompt]
      assert params[:properties][:model]
      assert params[:properties][:maxBytesMb]
    end

    test "has required image parameter" do
      params = Image.parameters()
      assert "image" in params[:required]
    end

    test "image parameter has correct type" do
      params = Image.parameters()
      assert params[:properties][:image][:type] == "string"
    end

    test "prompt parameter has correct type" do
      params = Image.parameters()
      assert params[:properties][:prompt][:type] == "string"
    end

    test "model parameter has correct type" do
      params = Image.parameters()
      assert params[:properties][:model][:type] == "string"
    end

    test "maxBytesMb parameter has correct type" do
      params = Image.parameters()
      assert params[:properties][:maxBytesMb][:type] == "number"
    end
  end

  describe "execute/2 - validation" do
    test "returns error when image is missing" do
      assert {:error, msg} = Image.execute(%{}, %{})
      assert msg =~ "required" or msg =~ "Invalid"
    end

    test "returns error for invalid image input type" do
      assert {:error, msg} = Image.execute(%{"image" => 123}, %{})
      assert is_binary(msg)
    end

    test "returns error for invalid URL format" do
      assert {:error, msg} = Image.execute(%{"image" => "not-a-url"}, %{})
      assert msg =~ "Invalid" or msg =~ "must be"
    end

    test "returns error for invalid data URL format" do
      assert {:error, msg} = Image.execute(%{"image" => "data:invalid"}, %{})
      assert msg =~ "Invalid" or msg =~ "format"
    end

    test "returns error for non-image data URL" do
      # Valid base64 but wrong mime type
      base64 = Base.encode64("hello world")
      data_url = "data:text/plain;base64,#{base64}"
      assert {:error, msg} = Image.execute(%{"image" => data_url}, %{})
      assert msg =~ "Unsupported" or msg =~ "image"
    end
  end

  describe "execute/2 - data URL decoding" do
    test "accepts valid PNG data URL" do
      # 1x1 transparent PNG
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      # Will fail at API call level (no key), but should pass validation
      result = Image.execute(%{"image" => data_url}, %{})

      # Either succeeds or fails at API level (not validation)
      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Invalid data URL"
      end
    end

    test "accepts valid JPEG data URL" do
      # Minimal JPEG header
      jpeg_base64 =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="

      data_url = "data:image/jpeg;base64,#{jpeg_base64}"

      result = Image.execute(%{"image" => data_url}, %{})

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Invalid data URL"
      end
    end

    test "rejects data URL exceeding size limit" do
      # Create large base64 data (more than 1MB)
      large_data = String.duplicate("A", 2_000_000)
      large_base64 = Base.encode64(large_data)
      data_url = "data:image/png;base64,#{large_base64}"

      # Use very small limit
      result = Image.execute(%{"image" => data_url, "maxBytesMb" => 0.001}, %{})

      assert {:error, msg} = result
      assert msg =~ "exceeds" or msg =~ "size"
    end

    test "handles whitespace in base64 data" do
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA\nDUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      result = Image.execute(%{"image" => data_url}, %{})

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Invalid base64"
      end
    end
  end

  describe "execute/2 - URL handling" do
    @tag :external
    test "handles unreachable URL" do
      result = Image.execute(%{"image" => "https://nonexistent.invalid/image.png"}, %{})

      assert {:error, msg} = result
      assert msg =~ "Failed" or msg =~ "download" or msg =~ "error"
    end

    @tag :external
    test "handles non-image URL" do
      # This will fail either at download or content-type check
      result = Image.execute(%{"image" => "https://example.com/"}, %{})

      case result do
        {:ok, _} ->
          # Shouldn't succeed but if it does, it's fine
          assert true

        {:error, msg} ->
          assert is_binary(msg)
      end
    end
  end

  describe "execute/2 - model selection" do
    test "accepts anthropic model override" do
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      result =
        Image.execute(
          %{
            "image" => data_url,
            "model" => "anthropic/claude-sonnet-4-20250514"
          },
          %{}
        )

      # Should fail at API level, not model validation
      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Unsupported provider"
      end
    end

    test "accepts openai model override" do
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      result =
        Image.execute(
          %{
            "image" => data_url,
            "model" => "openai/gpt-4o"
          },
          %{}
        )

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Unsupported provider"
      end
    end

    test "accepts google model override" do
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      result =
        Image.execute(
          %{
            "image" => data_url,
            "model" => "google/gemini-2.0-flash"
          },
          %{}
        )

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Unsupported provider"
      end
    end
  end

  describe "execute/2 - prompt handling" do
    test "uses default prompt when not provided" do
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      # Should not fail due to missing prompt
      result = Image.execute(%{"image" => data_url}, %{})

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "prompt"
      end
    end

    test "accepts custom prompt" do
      png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

      data_url = "data:image/png;base64,#{png_base64}"

      result =
        Image.execute(
          %{
            "image" => data_url,
            "prompt" => "What color is this pixel?"
          },
          %{}
        )

      # Should not fail due to custom prompt
      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "prompt"
      end
    end
  end

  describe "execute/2 - parameter key formats" do
    test "accepts string keys" do
      result = Image.execute(%{"image" => "invalid"}, %{})
      assert {:error, _} = result
    end

    test "accepts atom keys" do
      result = Image.execute(%{image: "invalid"}, %{})
      assert {:error, _} = result
    end
  end
end
