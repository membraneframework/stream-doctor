defmodule StreamDoctor.SenderPipeline do
  @moduledoc """
  Reads a media file (e.g. MP4), draws the frame-number bar on the video
  and streams the result to an RTMP URL.

  Options:
    * `:input` - Boombox input, e.g. a path to an MP4 file,
    * `:rtmp_url` - destination `rtmp://` URL,
    * `:realtime?` - pace the stream to real time (default `true`); set to
      `false` to push as fast as possible.

  The send moment of every video frame and audio buffer is broadcast to all
  metric collectors by `StreamDoctor.Probe.SendReporter` probes placed right
  before the RTMP sink.
  """

  use Membrane.Pipeline

  require Membrane.Pad

  @doc """
  Starts the pipeline (linked to the calling process) streaming `input` with
  the markers to `rtmp_url`; `opts` are the module options minus `:input` and
  `:rtmp_url`. Returns the pipeline pid.
  """
  @spec start_link(term(), String.t(), keyword()) :: pid()
  def start_link(input, rtmp_url, opts \\ []) do
    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(__MODULE__, [input: input, rtmp_url: rtmp_url] ++ opts)

    pipeline
  end

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      rtmp_url: Keyword.fetch!(opts, :rtmp_url),
      realtime?: Keyword.get(opts, :realtime?, true),
      awaiting_tracks: nil
    }

    spec = child(:boombox, %Boombox.Bin{input: Keyword.fetch!(opts, :input)})
    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :boombox, _ctx, state) do
    spec =
      [
        child(:rtmp_sink, %Membrane.RTMP.Sink{rtmp_url: state.rtmp_url, tracks: tracks})
      ] ++ Enum.map(tracks, &track_spec(&1, state))

    {[spec: spec], %{state | awaiting_tracks: MapSet.new(tracks)}}
  end

  @impl true
  def handle_element_end_of_stream(:rtmp_sink, Membrane.Pad.ref(kind, _id), _ctx, state) do
    awaiting_tracks = MapSet.delete(state.awaiting_tracks, kind)

    if MapSet.size(awaiting_tracks) == 0 do
      {[terminate: :normal], state}
    else
      {[], %{state | awaiting_tracks: awaiting_tracks}}
    end
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}

  defp track_spec(:video, state) do
    get_child(:boombox)
    |> via_out(:output, options: [kind: :video, codec: Membrane.RawVideo])
    |> child(:video_marker_encoder, StreamDoctor.Probe.VideoMarkerEncoder)
    |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
      preset: :veryfast,
      tune: :zerolatency,
      # Safety net only - the actual keyframe cadence is the time-based one
      # enforced by KeyframeScheduler below; this caps the GOP in frames in
      # case pts are missing (x264 default GOP is 250 frames, too sparse for
      # live-streaming ingests such as Amazon IVS)
      gop_size: 60
    })
    # keyframe every 2 s of stream time regardless of framerate - the interval
    # advised by live-streaming ingests (e.g. Amazon IVS)
    |> child(:keyframe_scheduler, __MODULE__.KeyframeScheduler)
    |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
    |> maybe_realtimer(:video, state)
    |> child(:video_send_reporter, %StreamDoctor.Probe.SendReporter{kind: :video})
    |> via_in(Membrane.Pad.ref(:video, 0))
    |> get_child(:rtmp_sink)
  end

  defp track_spec(:audio, state) do
    get_child(:boombox)
    |> via_out(:output, options: [kind: :audio, codec: Membrane.RawAudio])
    |> child(:audio_marker_encoder, StreamDoctor.Probe.AudioMarkerEncoder)
    |> child(:audio_encoder, %Membrane.Transcoder{output_stream_format: Membrane.AAC})
    |> maybe_realtimer(:audio, state)
    |> child(:audio_send_reporter, %StreamDoctor.Probe.SendReporter{kind: :audio})
    |> via_in(Membrane.Pad.ref(:audio, 0))
    |> get_child(:rtmp_sink)
  end

  defp maybe_realtimer(link, kind, %{realtime?: true}),
    do: child(link, {:realtimer, kind}, Membrane.Realtimer)

  defp maybe_realtimer(link, _kind, _state), do: link
end
