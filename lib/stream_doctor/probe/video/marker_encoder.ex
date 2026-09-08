defmodule StreamDoctor.Probe.Video.MarkerEncoder do
  @moduledoc "Draws the bar on each frame. Counts from 0, wraps at `StreamDoctor.Probe.Video.Bar.max_frame/0`."

  use Membrane.Filter

  alias StreamDoctor.Probe.Video.Bar
  alias Membrane.RawVideo

  def_input_pad(:input, accepted_format: %RawVideo{pixel_format: :I420})
  def_output_pad(:output, accepted_format: %RawVideo{pixel_format: :I420})

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{frame_number: 0, geometry: nil}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    geometry = Bar.geometry(stream_format.width, stream_format.height)
    {[stream_format: {:output, stream_format}], %{state | geometry: geometry}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    payload = Bar.draw(buffer.payload, state.geometry, state.frame_number)
    buffer = %{buffer | payload: payload}
    {[buffer: {:output, buffer}], %{state | frame_number: state.frame_number + 1}}
  end
end
