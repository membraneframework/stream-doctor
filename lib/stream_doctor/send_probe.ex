defmodule StreamDoctor.SendProbe do
  @moduledoc """
  Transparent filter reporting the frame number of every buffer passing
  through via the `on_frame` callback.

  Buffers are numbered by order of arrival, starting at 0 and wrapping at
  `StreamDoctor.Bar.max_frame/0` - the same numbering that
  `StreamDoctor.OverlayFilter` draws on the frames. Placed right before the
  RTMP sink (after the realtimer), it captures the moment a frame is actually
  sent out.

  Assumes one buffer per frame and no reordering between the overlay and this
  probe - which holds for the sender pipeline: the H264 encoder runs with
  `tune: :zerolatency` (no B-frames) and the parser outputs one access unit
  per buffer.
  """

  use Membrane.Filter

  alias StreamDoctor.Bar

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  def_options(
    on_frame: [
      spec: (non_neg_integer() -> any()),
      description: "Called with the frame number of every buffer passing through."
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{on_frame: opts.on_frame, frame_number: 0}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    state.on_frame.(state.frame_number)
    state = %{state | frame_number: rem(state.frame_number + 1, Bar.max_frame())}
    {[buffer: {:output, buffer}], state}
  end
end
