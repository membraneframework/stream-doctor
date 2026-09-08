defmodule StreamDoctor.SenderPipeline.KeyframeScheduler do
  @moduledoc false

  # Enforces a time-based keyframe interval, independent of the input framerate.
  #
  # Placed right after the H264 encoder, it watches the pts of passing buffers
  # and sends `Membrane.KeyframeRequestEvent` upstream (to the encoder) whenever
  # `interval` of stream time has elapsed since the previous request. The
  # encoder then encodes the next frame as a keyframe.
  #
  # The encoder's frame-count based `gop_size` cannot express "2 s" - the same
  # frame count means different durations at different framerates (60 frames is
  # 2 s at 30 fps but 2.4 s at 25 fps). Scheduling by pts sidesteps that and
  # also handles variable framerate.

  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  def_options(
    interval: [
      spec: Membrane.Time.t(),
      default: Membrane.Time.seconds(2),
      description: "Stream time between requested keyframes."
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{interval: opts.interval, next_request_pts: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # the first frame is a keyframe already, so the first request is due one
    # interval after it
    next_request_pts = state.next_request_pts || buffer.pts + state.interval

    if buffer.pts >= next_request_pts do
      state = %{state | next_request_pts: buffer.pts + state.interval}
      actions = [event: {:input, %Membrane.KeyframeRequestEvent{}}, buffer: {:output, buffer}]
      {actions, state}
    else
      {[buffer: {:output, buffer}], %{state | next_request_pts: next_request_pts}}
    end
  end
end
