defmodule StreamDoctor.SenderPipeline do
  @moduledoc """
  File in, markers on, RTMP out.

  Opts: `:input`, `:rtmp_url`, `:realtime?` (default true).
  """

  use Membrane.Pipeline

  require Membrane.Pad

  alias Membrane.{AAC, H264, H265, MP4, RawAudio, RawVideo, Transcoder}

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

    spec =
      child(:file_source, %Membrane.File.Source{
        location: Keyword.fetch!(opts, :input),
        seekable?: true
      })
      |> child(:demuxer, %MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :demuxer, _ctx, state) do
    tracks = Enum.map(tracks, fn {id, format} -> {id, to_kind(format)} end)
    kinds = Enum.map(tracks, fn {_id, kind} -> kind end)

    spec =
      [
        child(:rtmp_sink, %Membrane.RTMP.Sink{
          rtmp_url: state.rtmp_url,
          tracks: kinds,
          max_attempts: 10,
          # the sink would otherwise rebase the video alone, skewing the sync
          reset_timestamps: false
        })
      ] ++ Enum.map(tracks, &track_spec(&1, state))

    {[spec: spec], %{state | awaiting_tracks: MapSet.new(kinds)}}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

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

  defp to_kind(%AAC{}), do: :audio
  defp to_kind(%H264{}), do: :video
  defp to_kind(%H265{}), do: :video

  defp track_spec({track_id, :video}, state) do
    get_child(:demuxer)
    |> via_out(Membrane.Pad.ref(:output, track_id))
    |> child(:video_decoder, %Transcoder{output_stream_format: RawVideo})
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

  defp track_spec({track_id, :audio}, state) do
    get_child(:demuxer)
    |> via_out(Membrane.Pad.ref(:output, track_id))
    # the demuxer emits raw AAC frames with an esds config; FDK wants ADTS
    |> child(:aac_parser, AAC.Parser)
    |> child(:audio_decoder, %Transcoder{output_stream_format: RawAudio})
    |> child(:audio_marker_encoder, StreamDoctor.Probe.Audio.MarkerEncoder)
    |> child(:audio_encoder, %Membrane.AAC.FDK.Encoder{compensate_delay: true})
    |> maybe_realtimer(:audio, state)
    |> via_in(Membrane.Pad.ref(:audio, 0))
    |> get_child(:rtmp_sink)
  end

  defp maybe_realtimer(link, kind, %{realtime?: true}),
    do: child(link, {:realtimer, kind}, Membrane.Realtimer)

  defp maybe_realtimer(link, _kind, _state), do: link
end
