defmodule StreamDoctor.SenderPipeline.Egress.RTMP do
  @moduledoc """
  The RTMP output of a sender pipeline.
  """

  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.Pad
  alias StreamDoctor.Metric
  alias StreamDoctor.Probe.Video.Bar

  @type kind :: :video | :audio

  @spec link(%{optional(kind()) => Membrane.ChildrenSpec.t()}, String.t(), pid()) ::
          Membrane.ChildrenSpec.t()
  def link(track_builders, rtmp_url, notify) do
    [sink(rtmp_url, Map.keys(track_builders))] ++ Enum.map(track_builders, &track(&1, notify))
  end

  defp sink(rtmp_url, kinds) do
    child(:rtmp_sink, %Membrane.RTMP.Sink{
      rtmp_url: rtmp_url,
      tracks: kinds,
      max_attempts: 10,
      reset_timestamps: false
    })
  end

  defp track({:video, builder}, notify) do
    builder
    |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
    |> child({:realtimer, :video}, Membrane.Realtimer)
    |> child(:video_send_stamp, send_stamp(notify))
    |> via_in(Pad.ref(:video, 0))
    |> get_child(:rtmp_sink)
  end

  defp track({:audio, builder}, _notify) do
    builder
    |> child({:realtimer, :audio}, Membrane.Realtimer)
    |> via_in(Pad.ref(:audio, 0))
    |> get_child(:rtmp_sink)
  end

  defp send_stamp(notify) do
    sent = :counters.new(1, [])

    %Membrane.Debug.Filter{
      handle_buffer: fn _buffer ->
        number = rem(:counters.get(sent, 1), Bar.max_frame())
        :counters.add(sent, 1, 1)
        send(notify, {:video_frame_sent, number, Metric.now_ms()})
      end
    }
  end
end
