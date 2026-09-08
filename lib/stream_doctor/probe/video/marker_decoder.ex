defmodule StreamDoctor.Probe.Video.MarkerDecoder do
  @moduledoc "Reads the bar off each frame, reports to a collector (or logs)."

  use Membrane.Sink

  require Membrane.Logger

  alias StreamDoctor.Collector
  alias StreamDoctor.Probe.Video.Bar
  alias Membrane.RawVideo

  def_input_pad(:input, accepted_format: %RawVideo{pixel_format: :I420})

  def_options(
    collector: [
      spec: pid() | nil,
      default: nil,
      description: "gets `{:video_frame_received, n, pts_ms, t}`; nil = log"
    ]
  )

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

      {{:error, reason}, _collector} ->
        Membrane.Logger.debug("Failed to decode frame number: #{inspect(reason)}")
    end

    {[], state}
  end

  defp pts_ms(%{pts: nil}), do: nil
  defp pts_ms(%{pts: pts}), do: Membrane.Time.as_milliseconds(pts, :round)

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
