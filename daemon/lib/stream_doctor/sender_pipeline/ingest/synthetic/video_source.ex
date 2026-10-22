defmodule StreamDoctor.SenderPipeline.Ingest.Synthetic.VideoSource do
  @moduledoc """
  Generates I420 frames: a square bouncing left to right over scrolling colour bars.

  The frame-number bar is left to `StreamDoctor.Probe.Video.MarkerEncoder`, so the square
  stays above the strip that marker overwrites.
  """

  use Membrane.Source

  alias Membrane.{Buffer, RawVideo}
  alias StreamDoctor.Probe.Video.Bar

  def_options width: [spec: pos_integer()],
              height: [spec: pos_integer()],
              framerate: [spec: {pos_integer(), pos_integer()}],
              duration: [spec: Membrane.Time.t() | nil, default: nil]

  def_output_pad :output,
    accepted_format: %RawVideo{pixel_format: :I420},
    flow_control: :manual

  @bars [
    {210, 16, 146},
    {170, 166, 16},
    {145, 54, 34},
    {106, 202, 222},
    {81, 90, 240},
    {41, 240, 110}
  ]
  @square {235, 128, 128}

  @scroll 4

  @impl true
  def handle_init(_ctx, opts) do
    bar_top = opts.width |> Bar.geometry(opts.height) |> Bar.bar_top()
    {num, den} = opts.framerate
    side = even(max(8, min(div(bar_top, 4), div(opts.width, 4))))

    state = %{
      format: %RawVideo{
        width: opts.width,
        height: opts.height,
        pixel_format: :I420,
        framerate: opts.framerate,
        aligned: true
      },
      frame: 0,
      frame_duration: div(Membrane.Time.second() * den, num),
      frames: frames(opts.duration, num, den),
      rows: rows(opts.width),
      side: side,
      top: even(div(bar_top - side, 2)),
      span: opts.width - side
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, state.format}], state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    if over?(state) do
      {[end_of_stream: :output], state}
    else
      buffer = %Buffer{
        payload: frame(state),
        pts: state.frame * state.frame_duration,
        metadata: %{duration: state.frame_duration}
      }

      {[buffer: {:output, buffer}, redemand: :output], %{state | frame: state.frame + 1}}
    end
  end

  defp frames(nil, _num, _den), do: nil
  defp frames(duration, num, den), do: div(duration * num, den * Membrane.Time.second())

  defp over?(%{frames: nil}), do: false
  defp over?(%{frames: frames, frame: frame}), do: frame >= frames

  defp rows(width) do
    count = length(@bars)

    build = fn size, component ->
      for x <- 0..(size - 1), into: <<>> do
        <<@bars |> Enum.at(div(x * count, size)) |> elem(component)>>
      end
    end

    %{
      y: build.(width, 0),
      u: build.(div(width, 2), 1),
      v: build.(div(width, 2), 2)
    }
  end

  defp frame(state) do
    offset = rem(state.frame * @scroll, byte_size(state.rows.y))
    x = bounce(state)

    plane(state, :y, offset, x, state.side, state.top, 0) <>
      plane(state, :u, div(offset, 2), div(x, 2), div(state.side, 2), div(state.top, 2), 1) <>
      plane(state, :v, div(offset, 2), div(x, 2), div(state.side, 2), div(state.top, 2), 2)
  end

  defp plane(state, component, offset, x, side, top, index) do
    background = rotate(state.rows[component], offset)
    with_square = splice(background, x, side, elem(@square, index))
    height = div(state.format.height, if(component == :y, do: 1, else: 2))

    :binary.copy(background, top) <>
      :binary.copy(with_square, side) <>
      :binary.copy(background, height - top - side)
  end

  defp bounce(%{frame: frame, span: span}) do
    position = rem(frame * @scroll, 2 * span)
    even(if position <= span, do: position, else: 2 * span - position)
  end

  defp rotate(row, 0), do: row

  defp rotate(row, offset) do
    size = byte_size(row)
    binary_part(row, offset, size - offset) <> binary_part(row, 0, offset)
  end

  defp splice(row, x, length, value) do
    size = byte_size(row)

    binary_part(row, 0, x) <>
      :binary.copy(<<value>>, length) <>
      binary_part(row, x + length, size - x - length)
  end

  defp even(n), do: n - rem(n, 2)
end
