defmodule FrameMarker.DetectorSink do
  @moduledoc """
  Reads the frame-number bar (see `FrameMarker.Bar`) from each raw video frame
  and reports the result via the `on_frame` callback.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias FrameMarker.Bar
  alias Membrane.RawVideo

  def_input_pad(:input, accepted_format: %RawVideo{pixel_format: :I420})

  def_options(
    on_frame: [
      spec: ({:ok, non_neg_integer()} | {:error, atom()} -> any()) | nil,
      default: nil,
      description: """
      Called with `{:ok, frame_number}` or `{:error, reason}` for each
      received video frame. Defaults to logging the result.
      """
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{on_frame: opts.on_frame || (&log_result/1), geometry: nil}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    geometry = Bar.geometry(stream_format.width, stream_format.height)
    {[], %{state | geometry: geometry}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    state.on_frame.(Bar.decode(buffer.payload, state.geometry))
    {[], state}
  end

  defp log_result({:ok, frame_number}),
    do: Membrane.Logger.info("Decoded frame number: #{frame_number}")

  defp log_result({:error, reason}),
    do: Membrane.Logger.warning("Failed to decode frame number: #{inspect(reason)}")
end
