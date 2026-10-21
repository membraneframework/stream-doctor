defmodule StreamDoctor.Input.Synthetic.Video do
  @moduledoc """
  Parses the video settings of a synthetic input.
  """

  alias StreamDoctor.Input.Validate

  alias StreamDoctor.Probe.Video.Bar

  @type profile :: :baseline | :main | :high

  @type t :: %{
          width: 2..7680,
          height: 2..4320,
          fps: {pos_integer(), pos_integer()},
          gop_size: 1..2400,
          profile: profile() | nil,
          crf: 0..63 | nil,
          bitrate: 1_000..50_000_000 | nil
        }

  @max_width 7680
  @max_height 4320
  @max_fps 240

  @gop_seconds 2
  @max_gop 2400

  # the H264 encoder passes the framerate to the NIF as a pair of C ints
  @max_timebase 2_147_483_647

  # the generator emits 8-bit I420, so the 10-bit and 4:2:2/4:4:4 profiles would encode as high
  @profiles ~w(baseline main high)a

  @min_bitrate 1_000
  @max_bitrate 50_000_000

  @keys ~w(width height fps gop_size profile crf bitrate)

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) when is_map(config) do
    with :ok <- Validate.known_keys(config, @keys, "synthetic.video"),
         {:ok, width} <- dimension(config, "width", 640, @max_width),
         {:ok, height} <- dimension(config, "height", 360, @max_height),
         :ok <- bar_fits(width, height),
         {:ok, fps} <- fps(config),
         {:ok, gop_size} <-
           Validate.optional_int(config, "gop_size", 1..@max_gop, "synthetic.video"),
         {:ok, profile} <- Validate.member(config, "profile", @profiles, "synthetic.video"),
         {:ok, crf} <- Validate.optional_int(config, "crf", 0..63, "synthetic.video"),
         {:ok, bitrate} <-
           Validate.optional_int(
             config,
             "bitrate",
             @min_bitrate..@max_bitrate,
             "synthetic.video"
           ),
         :ok <- one_rate_control(crf, bitrate) do
      {:ok,
       %{
         width: width,
         height: height,
         fps: fps,
         gop_size: gop_size || default_gop(fps),
         profile: profile,
         crf: crf,
         bitrate: bitrate
       }}
    end
  end

  def parse(_other), do: {:error, "synthetic.video must be an object"}

  @spec encode_fps({pos_integer(), pos_integer()}) :: pos_integer() | [pos_integer()]
  def encode_fps({num, 1}), do: num
  def encode_fps({num, den}), do: [num, den]

  defp dimension(config, key, default, max) do
    value = Map.get(config, key, default)

    if Validate.even_in?(value, 2..max) do
      {:ok, value}
    else
      {:error,
       "synthetic.video.#{key} must be an even integer in 2..#{max}, got #{inspect(value)}"}
    end
  end

  defp bar_fits(width, height) do
    bar_height = height - Bar.bar_top(Bar.geometry(width, height))

    if height >= 2 * bar_height do
      :ok
    else
      {:error,
       "synthetic.video: the picture above the frame-number bar is too short: " <>
         "#{height}px, needs #{2 * bar_height}px"}
    end
  rescue
    error in RuntimeError -> {:error, "synthetic.video: #{Exception.message(error)}"}
  end

  defp fps(config) do
    case Map.get(config, "fps", 30) do
      value when is_integer(value) and value > 0 and value <= @max_fps ->
        {:ok, {value, 1}}

      [num, den] = pair ->
        if fps_pair?(num, den), do: {:ok, {num, den}}, else: fps_error(pair)

      value ->
        fps_error(value)
    end
  end

  defp default_gop({num, den}), do: max(1, round(@gop_seconds * num / den))

  defp fps_pair?(num, den) do
    is_integer(num) and is_integer(den) and den > 0 and num >= den and num <= @max_fps * den and
      num <= @max_timebase and den <= @max_timebase
  end

  defp fps_error(value) do
    {:error,
     "synthetic.video.fps must be an integer in 1..#{@max_fps}, or [numerator, denominator] " <>
       "whose ratio is in 1..#{@max_fps} and whose parts fit in 32 bits, got #{inspect(value)}"}
  end

  defp one_rate_control(nil, _bitrate), do: :ok
  defp one_rate_control(_crf, nil), do: :ok

  defp one_rate_control(_crf, _bitrate) do
    {:error,
     "synthetic.video: crf and bitrate cannot be used together; " <>
       "crf targets a quality, bitrate targets a rate"}
  end
end
