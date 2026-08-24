defmodule StreamDoctor.Probe.SendReporter do
  @moduledoc """
  Transparent filter broadcasting a `:video_frame_sent` event for every buffer
  passing through to all metric collectors (see
  `StreamDoctor.Metric.Collector.broadcast_send_event/1`). With no collector
  subscribed the broadcast is a no-op, so the filter can always sit in the
  sender pipeline.

  Buffers are numbered by order of arrival, starting at 0 and wrapping at
  `StreamDoctor.Probe.Bar.max_frame/0` - the same numbering that
  `StreamDoctor.Probe.VideoMarkerEncoder` draws on the frames. Placed right before the
  RTMP sink (after the realtimer), it captures the moment a frame is actually
  sent out.

  Assumes one buffer per frame and no reordering between the overlay and this
  probe - which holds for the sender pipeline: the H264 encoder runs with
  `tune: :zerolatency` (no B-frames) and the parser outputs one access unit
  per buffer.
  """

  use Membrane.Filter

  alias StreamDoctor.Metric.Collector
  alias StreamDoctor.Probe.Bar

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{frame_number: 0}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    Collector.broadcast_send_event(
      {:video_frame_sent, state.frame_number, System.monotonic_time(:millisecond)}
    )

    state = %{state | frame_number: rem(state.frame_number + 1, Bar.max_frame())}
    {[buffer: {:output, buffer}], state}
  end
end
