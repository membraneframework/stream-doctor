defmodule StreamDoctor.SenderPipeline do
  @moduledoc """
  File in, markers on, RTMP out.

  Opts: `:input`, `:rtmp_url`, `:realtime?` (default true).
  """

  use Membrane.Pipeline

  require Membrane.Pad

  @doc "Linked. Returns the pipeline pid."
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
        child(:rebase, __MODULE__.Rebase),
        child(:rtmp_sink, %Membrane.RTMP.Sink{
          rtmp_url: state.rtmp_url,
          tracks: tracks,
          max_attempts: 10
        })
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
    |> via_in(Membrane.Pad.ref(:input, :video))
    |> get_child(:rebase)
    |> via_out(Membrane.Pad.ref(:output, :video))
    |> child(:video_marker_encoder, StreamDoctor.Probe.Video.MarkerEncoder)
    |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
      preset: :veryfast,
      tune: :zerolatency,
      # safety net, real cadence comes from KeyframeScheduler
      gop_size: 60
    })
    |> child(:keyframe_scheduler, __MODULE__.KeyframeScheduler)
    |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
    |> maybe_realtimer(:video, state)
    |> child(:send_reporter, StreamDoctor.Probe.SendReporter)
    |> via_in(Membrane.Pad.ref(:video, 0))
    |> get_child(:rtmp_sink)
  end

  defp track_spec(:audio, state) do
    get_child(:boombox)
    |> via_out(:output, options: [kind: :audio, codec: Membrane.RawAudio])
    |> via_in(Membrane.Pad.ref(:input, :audio))
    |> get_child(:rebase)
    |> via_out(Membrane.Pad.ref(:output, :audio))
    |> child(:audio_marker_encoder, %StreamDoctor.Probe.Audio.MarkerEncoder{
      # FDK AAC-LC priming; RTMP has no way to signal it, so it's pre-compensated
      encoder_delay_samples: 2048
    })
    |> child(:audio_encoder, %Membrane.Transcoder{output_stream_format: Membrane.AAC})
    |> maybe_realtimer(:audio, state)
    |> via_in(Membrane.Pad.ref(:audio, 0))
    |> get_child(:rtmp_sink)
  end

  defp maybe_realtimer(link, kind, %{realtime?: true}),
    do: child(link, {:realtimer, kind}, Membrane.Realtimer)

  defp maybe_realtimer(link, _kind, _state), do: link
end
