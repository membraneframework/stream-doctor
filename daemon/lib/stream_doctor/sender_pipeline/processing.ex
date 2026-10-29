defmodule StreamDoctor.SenderPipeline.Processing do
  @moduledoc """
  Marks raw tracks with the marker a viewer decodes back, and encodes them.
  """

  import Membrane.ChildrenSpec

  alias StreamDoctor.OptionsParser.Publisher.Synthetic, as: Config
  alias StreamDoctor.Probe
  alias StreamDoctor.SenderPipeline.Egress.RTMP

  @type track_builders :: %{optional(RTMP.kind()) => Membrane.ChildrenSpec.t()}

  # a raw frame is megabytes, so every hop that can hold one is capped
  @raw_video_frames_autodemand_size 3

  @spec tracks(track_builders(), Config.t() | %{}) :: track_builders()
  def tracks(track_builders, config) do
    Map.new(track_builders, fn {kind, builder} -> {kind, track(kind, builder, config)} end)
  end

  defp track(:video, builder, config) do
    builder
    |> via_in(:input, auto_demand_size: @raw_video_frames_autodemand_size)
    |> child(:video_marker_encoder, Probe.Video.MarkerEncoder)
    |> via_in(:input, auto_demand_size: @raw_video_frames_autodemand_size)
    |> child(:encoder, video_encoder(settings(config, :video)))
  end

  defp track(:audio, builder, config) do
    builder
    |> child(:audio_marker_encoder, Probe.Audio.MarkerEncoder)
    |> child(:audio_encoder, audio_encoder(settings(config, :audio)))
  end

  defp settings(config, kind), do: Map.get(config, kind, %{})

  defp video_encoder(config) do
    encoder = %Membrane.H264.FFmpeg.Encoder{
      preset: :veryfast,
      tune: :zerolatency,
      gop_size: 60,
      profile: config[:profile],
      ffmpeg_params: x264_params(config[:bitrate])
    }

    encoder
    |> override(:gop_size, config[:gop_size])
    |> override(:crf, config[:crf])
  end

  defp audio_encoder(config) do
    encoder = %Membrane.AAC.FDK.Encoder{compensate_delay: true, bitrate: config[:bitrate]}

    override(encoder, :aot, config[:profile])
  end

  # the element always sets crf, which outranks a plain bitrate; x264-params is applied after it
  defp x264_params(nil), do: %{}
  defp x264_params(bitrate), do: %{"x264-params" => "bitrate=#{round(bitrate / 1000)}"}

  defp override(struct, _key, nil), do: struct
  defp override(struct, key, value), do: Map.put(struct, key, value)
end
