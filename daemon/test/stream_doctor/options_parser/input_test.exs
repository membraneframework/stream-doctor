defmodule StreamDoctor.OptionsParser.InputTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.OptionsParser.Input

  describe "parse/1" do
    test "a file path passes through untouched" do
      assert {:ok, {:file, "test.mp4"}} = Input.parse("test.mp4")
    end

    test "an empty synthetic config fills in defaults" do
      assert {:ok,
              {:synthetic,
               %{
                 video: %{
                   width: 640,
                   height: 360,
                   fps: {30, 1},
                   gop_size: 60,
                   profile: nil,
                   crf: nil
                 },
                 audio: %{sample_rate: 48_000, bitrate: nil, profile: :mpeg4_lc},
                 duration: nil
               }}} = Input.parse(%{"synthetic" => %{}})
    end

    test "settings are carried through" do
      config = %{
        "synthetic" => %{
          "video" => %{
            "width" => 1280,
            "height" => 720,
            "fps" => 60,
            "gop_size" => 15,
            "profile" => "high",
            "crf" => 18
          },
          "audio" => %{"sample_rate" => 44_100, "bitrate" => 128_000, "profile" => "mpeg2_lc"},
          "duration" => 5
        }
      }

      assert {:ok,
              {:synthetic,
               %{
                 video: %{
                   width: 1280,
                   height: 720,
                   fps: {60, 1},
                   gop_size: 15,
                   profile: :high,
                   crf: 18
                 },
                 audio: %{sample_rate: 44_100, bitrate: 128_000, profile: :mpeg2_lc},
                 duration: 5
               }}} = Input.parse(config)
    end

    test "fps accepts a numerator and denominator pair" do
      assert {:ok, {:synthetic, %{video: %{fps: {30_000, 1001}}}}} =
               Input.parse(%{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}})
    end

    test "the default gop size follows the framerate" do
      assert {:ok, {:synthetic, %{video: %{gop_size: 2}}}} =
               Input.parse(%{"synthetic" => %{"video" => %{"fps" => 1}}})

      assert {:ok, {:synthetic, %{video: %{gop_size: 480}}}} =
               Input.parse(%{"synthetic" => %{"video" => %{"fps" => 240}}})

      assert {:ok, {:synthetic, %{video: %{gop_size: 60}}}} =
               Input.parse(%{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}})
    end

    test "an unknown setting is rejected rather than ignored" do
      assert {:error, message} =
               Input.parse(%{"synthetic" => %{"video" => %{"frame_rate" => 30}}})

      assert message =~ "synthetic.video.frame_rate is not a known setting"
    end

    test "a frame the frame-number bar does not fit is rejected" do
      assert {:error, too_narrow} =
               Input.parse(%{"synthetic" => %{"video" => %{"width" => 160, "height" => 120}}})

      assert too_narrow =~ "Video too narrow for the frame-number bar"

      assert {:error, too_short} =
               Input.parse(%{"synthetic" => %{"video" => %{"width" => 640, "height" => 40}}})

      assert too_short =~ "Video too short for the frame-number bar"
    end

    test "a key beside synthetic is rejected rather than ignored" do
      assert {:error, message} = Input.parse(%{"synthetic" => %{}, "file" => "clip.mp4"})

      assert message =~ "input.file is not a known setting"
    end

    test "crf and bitrate cannot both set the rate control" do
      assert {:error, message} =
               Input.parse(%{"synthetic" => %{"video" => %{"crf" => 23, "bitrate" => 400_000}}})

      assert message =~ "cannot be used together"
    end

    test "anything that is neither a path nor a synthetic config is rejected" do
      assert {:error, "input must be a file path" <> _} = Input.parse(%{"blah" => 1})
    end
  end

  describe "summary/1" do
    test "a file reports its path" do
      assert "test.mp4" == Input.summary({:file, "test.mp4"})
    end

    test "a synthetic source reports its effective settings as JSON" do
      {:ok, parsed} = Input.parse(%{"synthetic" => %{"video" => %{"fps" => 25}}})

      assert %{"synthetic" => %{"video" => %{"fps" => 25, "width" => 640}}} =
               parsed |> Input.summary() |> JSON.encode!() |> JSON.decode!()
    end

    test "a fractional frame rate survives JSON encoding" do
      {:ok, parsed} = Input.parse(%{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}})

      assert %{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}} =
               parsed |> Input.summary() |> JSON.encode!() |> JSON.decode!()
    end
  end
end
