defmodule StreamDoctor.SenderPipeline.KeyframeScheduler do
  @moduledoc false

  # keyframe every `interval` of pts, whatever the framerate (gop_size can't do that)

  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  def_options(
    interval: [
      spec: Membrane.Time.t(),
      default: Membrane.Time.seconds(2),
      description: "pts between keyframes"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{interval: opts.interval, next_request_pts: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
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
