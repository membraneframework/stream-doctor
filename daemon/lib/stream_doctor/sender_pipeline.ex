defmodule StreamDoctor.SenderPipeline do
  @moduledoc """
  Reads the content of an MP4 file,
  adds audio and video markers and streams it via RTMP.

  Options: `:input`, `:rtmp_url`, `:on_live` (pid that gets `{:streamer_live, pipeline_pid}`
  once the first video frame reaches the sink).
  """

  use Membrane.Pipeline

  require Membrane.Pad

  alias Membrane.{AAC, H264, H265, MP4, RawAudio, RawVideo, Transcoder}

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
      on_live: Keyword.get(opts, :on_live),
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
          reset_timestamps: false
        })
      ] ++ Enum.map(tracks, &track_spec/1)

    {[spec: spec], %{state | awaiting_tracks: MapSet.new(kinds)}}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_element_start_of_stream(:rtmp_sink, Membrane.Pad.ref(:video, _id), _ctx, state) do
    if state.on_live, do: send(state.on_live, {:streamer_live, self()})
    {[], state}
  end

  @impl true
  def handle_element_start_of_stream(_child, _pad, _ctx, state), do: {[], state}

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

  defp track_spec({track_id, :video}) do
    get_child(:demuxer)
    |> via_out(Membrane.Pad.ref(:output, track_id))
    |> child(:video_decoder, %Transcoder{output_stream_format: RawVideo})
    |> child(:video_duration_adder, __MODULE__.DurationAdder)
    |> child(:video_marker_encoder, StreamDoctor.Probe.Video.MarkerEncoder)
    |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
      preset: :veryfast,
      tune: :zerolatency,
      gop_size: 60
    })
    |> child(:video_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
    |> child({:realtimer, :video}, Membrane.Realtimer)
    |> via_in(Membrane.Pad.ref(:video, 0))
    |> get_child(:rtmp_sink)
  end

  defp track_spec({track_id, :audio}) do
    get_child(:demuxer)
    |> via_out(Membrane.Pad.ref(:output, track_id))
    |> child(:aac_parser, AAC.Parser)
    |> child(:audio_decoder, %Transcoder{output_stream_format: RawAudio})
    |> child(:audio_marker_encoder, StreamDoctor.Probe.Audio.MarkerEncoder)
    |> child(:audio_encoder, %Membrane.AAC.FDK.Encoder{compensate_delay: true})
    |> child({:realtimer, :audio}, Membrane.Realtimer)
    |> via_in(Membrane.Pad.ref(:audio, 0))
    |> get_child(:rtmp_sink)
  end
end
