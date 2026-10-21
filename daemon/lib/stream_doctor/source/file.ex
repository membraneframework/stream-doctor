defmodule StreamDoctor.Source.File do
  @moduledoc """
  Reads an MP4 file and decodes its tracks to raw video and audio, with `metadata.duration`
  on every video buffer.
  """

  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.{AAC, H264, H265, MP4, Pad, RawAudio, RawVideo, Transcoder}
  alias StreamDoctor.Sink.RTMP
  alias StreamDoctor.Source.DurationAdder

  @spec spec(String.t()) :: Membrane.ChildrenSpec.t()
  def spec(path) do
    child(:file_source, %Membrane.File.Source{location: path, seekable?: true})
    |> child(:demuxer, %MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
  end

  @spec tracks([{term(), struct()}]) :: %{optional(RTMP.kind()) => Membrane.ChildrenSpec.t()}
  def tracks(tracks) do
    Enum.reduce(tracks, %{}, fn {track_id, format}, builders ->
      kind = kind(format)

      if Map.has_key?(builders, kind) do
        raise "RTMP carries one #{kind} track, the file has more than one"
      end

      Map.put(builders, kind, track(kind, track_id))
    end)
  end

  defp kind(%AAC{}), do: :audio
  defp kind(%H264{}), do: :video
  defp kind(%H265{}), do: :video

  defp track(:video, track_id) do
    get_child(:demuxer)
    |> via_out(Pad.ref(:output, track_id))
    |> child(:video_decoder, %Transcoder{output_stream_format: RawVideo})
    |> child(:video_duration_adder, DurationAdder)
  end

  defp track(:audio, track_id) do
    get_child(:demuxer)
    |> via_out(Pad.ref(:output, track_id))
    |> child(:aac_parser, AAC.Parser)
    |> child(:audio_decoder, %Transcoder{output_stream_format: RawAudio})
    |> child(:audio_converter, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 48_000}
    })
  end
end
