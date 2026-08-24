defmodule StreamDoctor.Probe.VideoMarkerDecoder do
  @moduledoc """
  Reads the frame-number bar (see `StreamDoctor.Probe.Bar`) from each raw video frame
  and reports the result via the `on_frame` callback.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias StreamDoctor.Probe.Bar
  alias Membrane.RawVideo

  def_input_pad(:input, accepted_format: %RawVideo{pixel_format: :I420})

  def_options(
    on_frame: [
      spec: ({:ok, non_neg_integer(), number() | nil} | {:error, atom()} -> any()) | nil,
      default: nil,
      description: """
      Called with `{:ok, frame_number, pts_ms}` (`pts_ms` is the buffer's
      presentation timestamp in milliseconds, `nil` when absent) or
      `{:error, reason}` for each received video frame. Defaults to logging
      the result.
      """
    ]
  )

  @doc "Number of distinct frame numbers; the marker's frame counter wraps at this value."
  @spec max_frame() :: pos_integer()
  defdelegate max_frame(), to: Bar

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{on_frame: opts.on_frame || (&log_result/1), geometry: nil}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    geometry = Bar.geometry(stream_format.width, stream_format.height)
    {[], %{state | geometry: geometry}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    result =
      case Bar.decode(buffer.payload, state.geometry) do
        {:ok, frame_number} -> {:ok, frame_number, pts_ms(buffer)}
        {:error, _reason} = error -> error
      end

    state.on_frame.(result)
    {[], state}
  end

  defp pts_ms(%{pts: nil}), do: nil
  defp pts_ms(%{pts: pts}), do: Membrane.Time.as_milliseconds(pts, :round)

  defp log_result({:ok, frame_number, _pts_ms}),
    do: Membrane.Logger.info("Decoded frame number: #{frame_number}")

  defp log_result({:error, reason}),
    do: Membrane.Logger.warning("Failed to decode frame number: #{inspect(reason)}")
end
