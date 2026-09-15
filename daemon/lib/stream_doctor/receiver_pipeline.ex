defmodule StreamDoctor.ReceiverPipeline do
  @moduledoc """
  Reads HLS playlist and decodes markers.

  Options: `:url`, `:collector`, `:live_edge?` (default false).
  """

  use Membrane.Pipeline

  alias Membrane.{AAC, H264, HTTPAdaptiveStream}

  @spec start_link(String.t(), keyword()) :: pid()
  def start_link(url, opts \\ []) do
    {:ok, _supervisor, pipeline} = Membrane.Pipeline.start_link(__MODULE__, [url: url] ++ opts)
    pipeline
  end

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      collector: Keyword.get(opts, :collector),
      awaiting_tracks: nil
    }

    spec =
      child(:hls_source, %HTTPAdaptiveStream.Source{
        url: Keyword.fetch!(opts, :url),
        live_edge_mode?: Keyword.get(opts, :live_edge?, false)
      })

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :hls_source, _ctx, state) do
    spec = Enum.map(tracks, &track_spec(&1, state))

    awaiting_tracks =
      MapSet.new(tracks, fn
        {:video_output, _format} -> :video
        {:audio_output, _format} -> :audio
      end)

    {[spec: spec], %{state | awaiting_tracks: awaiting_tracks}}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(child, :input, _ctx, state)
      when child in [:video_marker_decoder, :audio_marker_decoder] do
    kind = if child == :video_marker_decoder, do: :video, else: :audio
    awaiting_tracks = MapSet.delete(state.awaiting_tracks, kind)

    if MapSet.size(awaiting_tracks) == 0 do
      {[terminate: :normal], state}
    else
      {[], %{state | awaiting_tracks: awaiting_tracks}}
    end
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end

  defp track_spec({:video_output, _format}, state) do
    get_child(:hls_source)
    |> via_out(:video_output)
    |> child(:video_parser, %H264.Parser{
      output_alignment: :au,
      output_stream_structure: :annexb
    })
    |> child(:video_decoder, Membrane.H264.FFmpeg.Decoder)
    |> child(:video_marker_decoder, %StreamDoctor.Probe.Video.MarkerDecoder{
      collector: state.collector
    })
  end

  defp track_spec({:audio_output, _format}, state) do
    get_child(:hls_source)
    |> via_out(:audio_output)
    |> child(:audio_parser, %AAC.Parser{out_encapsulation: :ADTS})
    |> child(:audio_decoder, Membrane.AAC.FDK.Decoder)
    |> child(:audio_marker_decoder, %StreamDoctor.Probe.Audio.MarkerDecoder{
      collector: state.collector
    })
  end
end
