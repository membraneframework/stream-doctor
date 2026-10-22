defmodule StreamDoctor.SenderPipeline.Egress.RTMP do
  @moduledoc """
  The RTMP output of a sender pipeline.
  """

  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.Pad

  @type kind :: :video | :audio

  @spec link(%{optional(kind()) => Membrane.ChildrenSpec.t()}, String.t()) ::
          Membrane.ChildrenSpec.t()
  def link(track_builders, rtmp_url) do
    [sink(rtmp_url, Map.keys(track_builders))] ++ Enum.map(track_builders, &track/1)
  end

  defp sink(rtmp_url, kinds) do
    child(:rtmp_sink, %Membrane.RTMP.Sink{
      rtmp_url: rtmp_url,
      tracks: kinds,
      max_attempts: 10,
      reset_timestamps: false
    })
  end

  defp track({:video, builder}) do
    builder
    |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
    |> child({:realtimer, :video}, Membrane.Realtimer)
    |> via_in(Pad.ref(:video, 0))
    |> get_child(:rtmp_sink)
  end

  defp track({:audio, builder}) do
    builder
    |> child({:realtimer, :audio}, Membrane.Realtimer)
    |> via_in(Pad.ref(:audio, 0))
    |> get_child(:rtmp_sink)
  end
end
