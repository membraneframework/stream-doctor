defmodule StreamDoctor.HLS.CodecsTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.HLS.Codecs

  test "reads a video and an audio entry" do
    assert [
             %{type: :video, codec: :h264, profile: :high, level: "3.1"},
             %{type: :audio, codec: :aac, profile: :LC, level: nil}
           ] = Codecs.parse("avc1.64001f,mp4a.40.2")
  end

  test "constraint flags tell apart profiles sharing a profile_idc" do
    for {codecs, profile} <- [
          {"avc1.42001e", :baseline},
          {"avc1.42c01e", :constrained_baseline},
          {"avc1.64001f", :high},
          {"avc1.64081f", :progressive_high},
          {"avc1.640c1f", :constrained_high},
          {"avc1.6e101f", :high_10_intra}
        ] do
      assert [%{profile: ^profile}] = Codecs.parse(codecs)
    end
  end

  test "level_idc 11 with constraint_set3 means level 1b only for baseline, main and extended" do
    assert [%{profile: :constrained_baseline, level: "1b"}] = Codecs.parse("avc1.42d00b")
    assert [%{profile: :high, level: "1.1"}] = Codecs.parse("avc1.64100b")
    assert [%{profile: :high_10_intra, level: "1.1"}] = Codecs.parse("avc1.6e100b")
  end

  test "level_idc 9 means level 1b" do
    assert [%{level: "1b"}] = Codecs.parse("avc1.42c009")
  end

  test "levels above 1b divide by ten" do
    assert [%{level: "3.0"}] = Codecs.parse("avc1.64001e")
    assert [%{level: "4.1"}] = Codecs.parse("avc1.640029")
  end

  test "known aac object types map to profiles" do
    assert [%{codec: :aac, profile: :LC}] = Codecs.parse("mp4a.40.2")
    assert [%{codec: :aac, profile: :HE}] = Codecs.parse("mp4a.40.5")
    assert [%{codec: :aac, profile: :HEv2}] = Codecs.parse("mp4a.40.29")
  end

  test "mp4a object types that are not aac are not reported as aac" do
    assert [%{type: :unknown, raw: "mp4a.40.34"}] = Codecs.parse("mp4a.40.34")
    assert [%{type: :unknown, raw: "mp4a.40.0"}] = Codecs.parse("mp4a.40.0")
    assert [%{type: :unknown, raw: "mp4a.40.99"}] = Codecs.parse("mp4a.40.99")
  end

  test "codecs this module does not parse are passed through raw" do
    assert [%{type: :unknown, raw: "hvc1.1.6.L93.B0"}] = Codecs.parse("hvc1.1.6.L93.B0")
    assert [%{type: :unknown, raw: "av01.0.04M.08"}] = Codecs.parse("av01.0.04M.08")
  end

  test "an avc1 entry whose parameters do not decode is still reported as h264" do
    assert [%{type: :video, codec: :h264, profile: nil, level: nil}] = Codecs.parse("avc1.zzzz")
    assert [%{type: :video, codec: :h264, profile: nil, level: nil}] = Codecs.parse("avc1.6400")
  end

  test "an absent CODECS attribute yields no tracks" do
    assert [] == Codecs.parse(nil)
  end
end
