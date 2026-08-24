defmodule StreamDoctor.Probe.Bar do
  # Encoding and decoding of the frame-number bar drawn at the bottom of the
  # video. Implementation detail of the video marker probes - not part of the
  # public API.
  #
  # The bar is a black strip spanning the whole width of the frame. It
  # contains 17 squares, left to right:
  #
  #   * square 0 - always white (reference for "1"/white level),
  #   * square 1 - always black (reference for "0"/black level),
  #   * squares 2..15 - 14 data bits of the frame number, MSB first
  #     (white = 1, black = 0), so frame numbers wrap at 16384,
  #   * square 16 - even-parity bit over the 14 data bits.
  #
  # The geometry is derived deterministically from the frame resolution, so
  # the reader reconstructs it from the received stream format without any
  # side channel. Operates on raw video in I420 pixel format.
  @moduledoc false

  import Bitwise

  @data_bits 14
  @total_squares 2 + @data_bits + 1
  @max_frame 1 <<< @data_bits

  @white 235
  @black 16
  @neutral_chroma 128

  # Minimal luma spread between the two reference squares required to accept the bar
  @min_contrast 32

  @type geometry :: %{
          width: pos_integer(),
          height: pos_integer(),
          square: pos_integer(),
          pad: pos_integer(),
          bar_top: non_neg_integer(),
          square_top: non_neg_integer(),
          xs: [non_neg_integer()]
        }

  @doc "Number of distinct frame numbers; frame counter wraps at this value."
  @spec max_frame() :: pos_integer()
  def max_frame(), do: @max_frame

  @doc """
  Computes the bar geometry for the given resolution.

  All coordinates are even so the bar aligns with 4:2:0 chroma subsampling.
  """
  @spec geometry(pos_integer(), pos_integer()) :: geometry()
  def geometry(width, height) do
    square = width |> div(24) |> max(8) |> even()
    gap = square |> div(4) |> max(2) |> even()
    pad = gap

    needed_width = pad + @total_squares * (square + gap)

    if needed_width > width do
      raise "Video too narrow for the frame-number bar: " <>
              "#{width}px available, #{needed_width}px needed (min. ~180px)"
    end

    bar_height = square + 2 * pad

    %{
      width: width,
      height: height,
      square: square,
      pad: pad,
      bar_top: height - bar_height,
      square_top: height - pad - square,
      xs: Enum.map(0..(@total_squares - 1), &(pad + &1 * (square + gap)))
    }
  end

  @doc """
  Draws the bar with the given frame number onto an I420 payload.
  """
  @spec draw(binary(), geometry(), non_neg_integer()) :: binary()
  def draw(payload, %{width: width, height: height} = geometry, frame_number) do
    y_size = width * height
    chroma_size = div(y_size, 4)

    <<y::binary-size(y_size), u::binary-size(chroma_size), v::binary-size(chroma_size)>> =
      payload

    bits = encode(frame_number)

    background_row = :binary.copy(<<@black>>, width)
    squares_row = squares_row(geometry, bits)

    bar_rows =
      for row <- geometry.bar_top..(height - 1) do
        if row >= geometry.square_top and row < geometry.square_top + geometry.square,
          do: squares_row,
          else: background_row
      end

    y = binary_part(y, 0, geometry.bar_top * width) <> IO.iodata_to_binary(bar_rows)

    chroma_width = div(width, 2)
    chroma_bar_top = div(geometry.bar_top, 2)
    chroma_kept = chroma_bar_top * chroma_width
    chroma_fill = :binary.copy(<<@neutral_chroma>>, chroma_size - chroma_kept)

    u = binary_part(u, 0, chroma_kept) <> chroma_fill
    v = binary_part(v, 0, chroma_kept) <> chroma_fill

    y <> u <> v
  end

  @doc """
  Reads the frame number back from an I420 payload.

  Returns `{:ok, frame_number}`, `{:error, :markers_not_found}` when the two
  reference squares don't show enough contrast (no bar in the frame), or
  `{:error, :parity_mismatch}` when the parity bit doesn't match the data bits.
  """
  @spec decode(binary(), geometry()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  def decode(payload, %{width: width, height: height} = geometry) do
    y = binary_part(payload, 0, width * height)

    [white_reference, black_reference | rest] =
      Enum.map(geometry.xs, &square_luma_average(y, geometry, &1))

    if white_reference - black_reference < @min_contrast do
      {:error, :markers_not_found}
    else
      threshold = (white_reference + black_reference) / 2
      bits = Enum.map(rest, &if(&1 > threshold, do: 1, else: 0))
      {data, [parity]} = Enum.split(bits, @data_bits)

      if rem(Enum.sum(data), 2) == parity,
        do: {:ok, Integer.undigits(data, 2)},
        else: {:error, :parity_mismatch}
    end
  end

  @spec encode(non_neg_integer()) :: [0 | 1]
  defp encode(frame_number) do
    n = rem(frame_number, @max_frame)
    data = for i <- (@data_bits - 1)..0//-1, do: n >>> i &&& 1
    parity = rem(Enum.sum(data), 2)
    [1, 0] ++ data ++ [parity]
  end

  defp squares_row(geometry, bits) do
    white_square = :binary.copy(<<@white>>, geometry.square)

    geometry.xs
    |> Enum.zip(bits)
    |> Enum.filter(fn {_x, bit} -> bit == 1 end)
    |> Enum.reduce(:binary.copy(<<@black>>, geometry.width), fn {x, 1}, row ->
      binary_part(row, 0, x) <>
        white_square <>
        binary_part(row, x + geometry.square, geometry.width - x - geometry.square)
    end)
  end

  # Averages luma over the central part of a square, skipping a quarter-side
  # margin on each edge to stay clear of compression artifacts at the borders.
  defp square_luma_average(y_plane, geometry, x) do
    margin = div(geometry.square, 4)
    x0 = x + margin
    y0 = geometry.square_top + margin
    side = geometry.square - 2 * margin

    values =
      for row <- y0..(y0 + side - 1) do
        y_plane |> binary_part(row * geometry.width + x0, side) |> :binary.bin_to_list()
      end

    values = List.flatten(values)
    Enum.sum(values) / length(values)
  end

  defp even(n), do: n - rem(n, 2)
end
