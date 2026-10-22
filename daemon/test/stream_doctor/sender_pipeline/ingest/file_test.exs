defmodule StreamDoctor.SenderPipeline.Ingest.FileTest do
  use ExUnit.Case, async: true

  alias Membrane.{AAC, H264}
  alias StreamDoctor.SenderPipeline.Ingest.File

  test "an audio and a video track each become a builder of their kind" do
    assert %{video: _video, audio: _audio} = File.tracks([{1, %H264{}}, {2, %AAC{}}])
  end

  test "a second track of the same kind is refused instead of silently dropped" do
    assert_raise RuntimeError, ~r/one audio track/, fn ->
      File.tracks([{1, %H264{}}, {2, %AAC{}}, {3, %AAC{}}])
    end
  end
end
