defmodule StreamDoctor.Probe.Video.MarkerEncoder do
  @moduledoc """
  Draws the bar on each frame. Frames are numbered in arrival order from zero, wrapping at
  `StreamDoctor.Probe.Video.Bar.max_frame/0`.
  """

  use Membrane.Filter

  alias Membrane.RawVideo
  alias StreamDoctor.Probe.Video.Bar

  def_input_pad :input, accepted_format: %RawVideo{pixel_format: :I420}
  def_output_pad :output, accepted_format: %RawVideo{pixel_format: :I420}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{bar: nil, frame_count: 0}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    bar = Bar.new(stream_format.width, stream_format.height)
    {[stream_format: {:output, stream_format}], %{state | bar: bar}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    buffer = %{buffer | payload: Bar.encode(state.bar, buffer.payload, state.frame_count)}

    {[buffer: {:output, buffer}],
     %{state | frame_count: rem(state.frame_count + 1, Bar.max_frame())}}
  end
end
