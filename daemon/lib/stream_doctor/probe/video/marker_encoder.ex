defmodule StreamDoctor.Probe.Video.MarkerEncoder do
  @moduledoc """
  Draws the bar on each frame. The frame number is the pts in frame durations, so number 0 is
  source time zero whether or not a frame sits there; wraps at
  `StreamDoctor.Probe.Video.Bar.max_frame/0`.
  """

  use Membrane.Filter

  alias Membrane.RawVideo
  alias StreamDoctor.Probe.Video.Bar

  def_input_pad :input, accepted_format: %RawVideo{pixel_format: :I420}
  def_output_pad :output, accepted_format: %RawVideo{pixel_format: :I420}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{geometry: nil, frame_duration: nil, held: nil}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    geometry = Bar.geometry(stream_format.width, stream_format.height)
    {[stream_format: {:output, stream_format}], %{state | geometry: geometry}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{frame_duration: nil, held: nil} = state) do
    {[], %{state | held: buffer}}
  end

  def handle_buffer(:input, buffer, _ctx, %{frame_duration: nil, held: held} = state) do
    frame_duration = buffer.pts - held.pts

    if frame_duration <= 0 do
      raise "Non-increasing video pts: #{held.pts} then #{buffer.pts}"
    end

    state = %{state | frame_duration: frame_duration, held: nil}
    {[buffer: {:output, [draw(held, state), draw(buffer, state)]}], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, draw(buffer, state)}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{held: nil} = state) do
    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(:input, _ctx, %{held: held} = state) do
    buffer = %{held | payload: Bar.draw(held.payload, state.geometry, 0)}
    {[buffer: {:output, buffer}, end_of_stream: :output], %{state | held: nil}}
  end

  defp draw(buffer, state) do
    frame_number = round(buffer.pts / state.frame_duration)
    %{buffer | payload: Bar.draw(buffer.payload, state.geometry, frame_number)}
  end
end
