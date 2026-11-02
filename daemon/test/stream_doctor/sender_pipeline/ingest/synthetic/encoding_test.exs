defmodule StreamDoctor.SenderPipeline.Ingest.Synthetic.EncodingTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.H264
  alias Membrane.Testing
  alias StreamDoctor.SenderPipeline.Ingest.Synthetic.VideoSource

  defp encode(encoder_options) do
    spec =
      child(:source, %VideoSource{width: 320, height: 240, framerate: {30, 1}})
      |> via_in(:input, auto_demand_size: 3)
      |> child(:marker, StreamDoctor.Probe.Video.MarkerEncoder)
      |> child(
        :encoder,
        struct!(Membrane.H264.FFmpeg.Encoder, [preset: :veryfast] ++ encoder_options)
      )
      |> child(:parser, %H264.Parser{output_stream_structure: :avc1})
      |> child(:sink, Testing.Sink)

    pid = Testing.Pipeline.start_link_supervised!(spec: spec)
    on_exit(fn -> Testing.Pipeline.terminate(pid) end)
    pid
  end

  test "the requested profile is what the encoded bitstream actually declares" do
    assert_sink_stream_format(encode(profile: :main), :sink, %H264{profile: :main}, 15_000)
    assert_sink_stream_format(encode(profile: :high), :sink, %H264{profile: :high}, 15_000)

    # x264 never emits the features that separate plain baseline from constrained
    assert_sink_stream_format(
      encode(profile: :baseline),
      :sink,
      %H264{profile: :constrained_baseline},
      15_000
    )
  end
end
