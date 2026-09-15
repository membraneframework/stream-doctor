defmodule StreamDoctor.Probe.Video.MarkerEncoder do
  @moduledoc """
  Draws the bar on each frame. The frame number is the pts divided by the frame duration, so
  number 0 is source time zero whether or not a frame sits there. It wraps at
  `StreamDoctor.Probe.Video.Bar.max_frame/0`. Every buffer must carry `metadata.duration`, see
  `StreamDoctor.SenderPipeline.DurationAdder`.
  """

  use Membrane.Filter

  alias Membrane.RawVideo
  alias StreamDoctor.Probe.Video.Bar

  def_input_pad :input, accepted_format: %RawVideo{pixel_format: :I420}
  def_output_pad :output, accepted_format: %RawVideo{pixel_format: :I420}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{geometry: nil}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    geometry = Bar.geometry(stream_format.width, stream_format.height)
    {[stream_format: {:output, stream_format}], %{state | geometry: geometry}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    frame_number = round(buffer.pts / buffer.metadata.duration)
    buffer = %{buffer | payload: Bar.draw(buffer.payload, state.geometry, frame_number)}
    {[buffer: {:output, buffer}], state}
  end
end
