defmodule FrameMarker.ReceiverPipeline do
  @moduledoc """
  Reads an HLS playlist, decodes the video and restores frame numbers from the
  bar drawn by `FrameMarker.OverlayFilter`.

  Options:
    * `:url` - URL of the HLS playlist (`.m3u8`),
    * `:on_frame` - optional callback, see `FrameMarker.DetectorSink`.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    spec = child(:boombox, %Boombox.Bin{input: {:hls, Keyword.fetch!(opts, :url)}})
    {[spec: spec], %{on_frame: Keyword.get(opts, :on_frame)}}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :boombox, _ctx, state) do
    spec = Enum.map(tracks, &track_spec(&1, state))
    {[spec: spec], state}
  end

  @impl true
  def handle_element_end_of_stream(:detector, :input, _ctx, state) do
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}

  defp track_spec(:video, state) do
    get_child(:boombox)
    |> via_out(:output, options: [kind: :video, codec: Membrane.RawVideo])
    |> child(:detector, %FrameMarker.DetectorSink{on_frame: state.on_frame})
  end

  defp track_spec(:audio, _state) do
    get_child(:boombox)
    |> via_out(:output, options: [kind: :audio])
    |> child(:audio_sink, %Membrane.Debug.Sink{})
  end
end
