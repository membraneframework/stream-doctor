defmodule StreamDoctor.Probe.SendReporter do
  @moduledoc """
  Transparent filter broadcasting a send event for every buffer passing
  through to all metric collectors (see
  `StreamDoctor.Metric.Collector.broadcast_send_event/1`). With no collector
  subscribed the broadcast is a no-op, so the filter can always sit in the
  sender pipeline. Placed right before the RTMP sink (after the realtimer), it
  captures the moment media is actually sent out.

  Options:

    * `:kind` - `:video` (default) or `:audio`.

  `:video` emits `{:video_frame_sent, frame, t}`. Buffers are numbered by
  order of arrival, starting at 0 and wrapping at
  `StreamDoctor.Probe.Bar.max_frame/0` - the same numbering that
  `StreamDoctor.Probe.VideoMarkerEncoder` draws on the frames. Assumes one
  buffer per frame and no reordering between the overlay and this probe -
  which holds for the sender pipeline: the H264 encoder runs with
  `tune: :zerolatency` (no B-frames) and the parser outputs one access unit
  per buffer.

  `:audio` emits `{:audio_sent, media_ms, t}`, where `media_ms` is the
  buffer's position on the audio track relative to its first buffer - the
  same origin `StreamDoctor.Probe.AudioMarkerEncoder` counts its symbols
  from, so symbol `m` sits at `m * symbol_ms` on this axis. Requires the
  buffers to carry pts.
  """

  use Membrane.Filter

  alias StreamDoctor.Metric.Collector
  alias StreamDoctor.Probe.Bar

  def_options(kind: [spec: :video | :audio, default: :video])

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{kind: opts.kind, frame_number: 0, first_pts: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{kind: :video} = state) do
    Collector.broadcast_send_event({:video_frame_sent, state.frame_number, now_ms()})
    state = %{state | frame_number: rem(state.frame_number + 1, Bar.max_frame())}
    {[buffer: {:output, buffer}], state}
  end

  def handle_buffer(:input, %{pts: nil} = buffer, _ctx, %{kind: :audio} = state) do
    {[buffer: {:output, buffer}], state}
  end

  def handle_buffer(:input, buffer, _ctx, %{kind: :audio} = state) do
    first_pts = state.first_pts || buffer.pts
    media_ms = Membrane.Time.as_milliseconds(buffer.pts - first_pts, :round)
    Collector.broadcast_send_event({:audio_sent, media_ms, now_ms()})
    {[buffer: {:output, buffer}], %{state | first_pts: first_pts}}
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
