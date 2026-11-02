defmodule StreamDoctor.OptionsParser.PublisherTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.OptionsParser.Publisher

  describe "parse/1" do
    test "a file is named explicitly" do
      assert {:ok, {:file, "test.mp4"}} = Publisher.parse(%{"file" => "test.mp4"})
    end

    test "an empty synthetic config fills in defaults" do
      assert {:ok,
              {:synthetic,
               %{
                 video: %{
                   width: 640,
                   height: 360,
                   fps: [30, 1],
                   gop_size: 60,
                   profile: nil,
                   crf: nil
                 },
                 audio: %{sample_rate: 48_000, bitrate: nil, profile: :mpeg4_lc},
                 duration: nil
               }}} = Publisher.parse(%{"synthetic" => %{}})
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
                   fps: [60, 1],
                   gop_size: 15,
                   profile: :high,
                   crf: 18
                 },
                 audio: %{sample_rate: 44_100, bitrate: 128_000, profile: :mpeg2_lc},
                 duration: 5
               }}} = Publisher.parse(config)
    end

    test "fps accepts a numerator and denominator pair" do
      assert {:ok, {:synthetic, %{video: %{fps: [30_000, 1001]}}}} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}})
    end

    test "the default gop size follows the framerate" do
      assert {:ok, {:synthetic, %{video: %{gop_size: 2}}}} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"fps" => 1}}})

      assert {:ok, {:synthetic, %{video: %{gop_size: 480}}}} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"fps" => 240}}})

      assert {:ok, {:synthetic, %{video: %{gop_size: 60}}}} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}})
    end

    test "the encoder tuning is checked against what x264 knows" do
      assert {:ok, {:synthetic, %{video: %{preset: :placebo, tune: :grain}}}} =
               Publisher.parse(%{
                 "synthetic" => %{"video" => %{"preset" => "placebo", "tune" => "grain"}}
               })

      assert {:error, message} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"preset" => "turbo"}}})

      assert message =~ "invalid value for :preset option"
    end

    test "an unknown setting is rejected rather than ignored" do
      assert {:error, message} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"frame_rate" => 30}}})

      assert message =~ "synthetic.video.frame_rate is not a known setting"
    end

    test "file and synthetic together are rejected rather than one of them ignored" do
      assert {:error, message} = Publisher.parse(%{"synthetic" => %{}, "file" => "clip.mp4"})

      assert message =~ "either file or synthetic, not both"
    end

    test "a key beside file is rejected rather than ignored" do
      assert {:error, message} = Publisher.parse(%{"file" => "clip.mp4", "fps" => 30})

      assert message =~ "input.fps is not a known setting"
    end

    test "duration is any positive integer, with no ceiling" do
      assert {:ok, {:synthetic, %{duration: 1_000_000}}} =
               Publisher.parse(%{"synthetic" => %{"duration" => 1_000_000}})

      assert {:error, message} = Publisher.parse(%{"synthetic" => %{"duration" => 0}})
      assert message =~ "invalid value for :duration option: expected positive integer"
    end

    test "gop size is bounded by what the encoder NIF takes as a C int" do
      assert {:ok, {:synthetic, %{video: %{gop_size: 2_147_483_647}}}} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"gop_size" => 2_147_483_647}}})

      assert {:error, message} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"gop_size" => 2_147_483_648}}})

      assert message =~ "invalid value for :gop_size option: expected one of 1..2147483647"
    end

    test "crf stops where 8-bit x264 stops" do
      assert {:ok, {:synthetic, %{video: %{crf: 51}}}} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"crf" => 51}}})

      assert {:error, message} =
               Publisher.parse(%{"synthetic" => %{"video" => %{"crf" => 52}}})

      assert message =~ "expected one of 0..51"
    end

    test "crf and bitrate may both be given" do
      assert {:ok, {:synthetic, %{video: %{crf: 23, bitrate: 400_000}}}} =
               Publisher.parse(%{
                 "synthetic" => %{"video" => %{"crf" => 23, "bitrate" => 400_000}}
               })
    end

    test "a wrong type names the field that is wrong, not the whole input" do
      assert {:error, synthetic} = Publisher.parse(%{"synthetic" => true})
      assert synthetic =~ "input: invalid value for :synthetic option: must be an object"

      assert {:error, file} = Publisher.parse(%{"file" => 42})
      assert file =~ "input: invalid value for :file option: expected string"
    end

    test "anything that names neither a file nor a synthetic config is rejected" do
      assert {:error, "input.blah is not a known setting" <> _} = Publisher.parse(%{"blah" => 1})
      assert {:error, "input must name either file or synthetic" <> _} = Publisher.parse(%{})
      assert {:error, "input must be an object"} = Publisher.parse("test.mp4")
    end
  end

  describe "summary/1" do
    test "a file reports its path" do
      assert %{file: "test.mp4"} == Publisher.summary({:file, "test.mp4"})
    end

    test "a synthetic source reports its effective settings as JSON" do
      {:ok, parsed} = Publisher.parse(%{"synthetic" => %{"video" => %{"fps" => 25}}})

      assert %{"synthetic" => %{"video" => %{"fps" => [25, 1], "width" => 640}}} =
               parsed |> Publisher.summary() |> JSON.encode!() |> JSON.decode!()
    end

    test "a fractional frame rate survives JSON encoding" do
      {:ok, parsed} = Publisher.parse(%{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}})

      assert %{"synthetic" => %{"video" => %{"fps" => [30_000, 1001]}}} =
               parsed |> Publisher.summary() |> JSON.encode!() |> JSON.decode!()
    end
  end
end
