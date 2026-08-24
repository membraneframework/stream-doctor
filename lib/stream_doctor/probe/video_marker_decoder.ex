defmodule StreamDoctor.Probe.VideoMarkerDecoder do
  @moduledoc """
  Reads the frame-number bar from each raw video frame and reports the result
  to the configured `StreamDoctor.Metric.Collector` (or logs it when none is
  given).
  """

  use Membrane.Sink

  require Membrane.Logger

  alias StreamDoctor.Metric.Collector
  alias StreamDoctor.Probe.Bar
  alias Membrane.RawVideo

  def_input_pad(:input, accepted_format: %RawVideo{pixel_format: :I420})

  def_options(
    collector: [
      spec: pid() | nil,
      default: nil,
      description: """
      `StreamDoctor.Metric.Collector` to report to: a
      `{:video_frame_received, frame_number, pts_ms, t}` event for each
      decoded frame (`pts_ms` is the buffer's presentation timestamp in
      milliseconds, `nil` when absent) and `{:undecoded, :video, reason, t}`
      for each frame without a readable bar. With no collector the results
      are logged.
      """
    ]
  )

  @doc "Number of distinct frame numbers; the marker's frame counter wraps at this value."
  @spec max_frame() :: pos_integer()
  defdelegate max_frame(), to: Bar

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{collector: opts.collector, geometry: nil}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    geometry = Bar.geometry(stream_format.width, stream_format.height)
    {[], %{state | geometry: geometry}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case {Bar.decode(buffer.payload, state.geometry), state.collector} do
      {{:ok, frame_number}, nil} ->
        Membrane.Logger.info("Decoded frame number: #{frame_number}")

      {{:error, reason}, nil} ->
        Membrane.Logger.warning("Failed to decode frame number: #{inspect(reason)}")

      {{:ok, frame_number}, collector} ->
        Collector.event(
          collector,
          {:video_frame_received, frame_number, pts_ms(buffer), now_ms()}
        )

      {{:error, reason}, collector} ->
        Collector.event(collector, {:undecoded, :video, reason, now_ms()})
    end

    {[], state}
  end

  defp pts_ms(%{pts: nil}), do: nil
  defp pts_ms(%{pts: pts}), do: Membrane.Time.as_milliseconds(pts, :round)

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
