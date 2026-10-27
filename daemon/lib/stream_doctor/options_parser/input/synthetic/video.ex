defmodule StreamDoctor.OptionsParser.Input.Synthetic.Video do
  @moduledoc """
  Parses the video settings of a synthetic input.
  """

  alias StreamDoctor.OptionsParser.Options
  alias StreamDoctor.Probe.Video.Bar

  @type profile :: :baseline | :main | :high

  @type t :: %{
          width: 2..7680,
          height: 2..4320,
          fps: [pos_integer()],
          gop_size: pos_integer(),
          profile: profile() | nil,
          crf: 0..63 | nil,
          bitrate: 1_000..50_000_000 | nil
        }

  @scope "synthetic.video"

  @max_width 7680
  @max_height 4320
  @max_fps 240

  @gop_seconds 2

  # the H264 encoder passes the framerate to the NIF as a pair of C ints
  @max_timebase 2_147_483_647

  # the generator emits 8-bit I420, so the 10-bit and 4:2:2/4:4:4 profiles would encode as high
  @profiles ~w(baseline main high)a

  @spec schema() :: keyword()
  def schema do
    [
      width: [type: {:custom, __MODULE__, :dimension, [@max_width]}, default: 640],
      height: [type: {:custom, __MODULE__, :dimension, [@max_height]}, default: 360],
      fps: [type: {:custom, __MODULE__, :framerate, []}, default: 30],
      gop_size: [type: :pos_integer],
      profile: [type: {:in, @profiles}],
      crf: [type: {:in, 0..63}],
      bitrate: [type: {:in, 1_000..50_000_000}]
    ]
  end

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) do
    with {:ok, video} <- Options.validate(config, schema(), @scope),
         :ok <- bar_fits(video.width, video.height) do
      {:ok,
       Map.merge(%{gop_size: default_gop(video.fps), profile: nil, crf: nil, bitrate: nil}, video)}
    end
  end

  @doc false
  @spec dimension(term(), pos_integer()) :: {:ok, pos_integer()} | {:error, String.t()}
  def dimension(value, max)
      when is_integer(value) and value >= 2 and value <= max and rem(value, 2) == 0 do
    {:ok, value}
  end

  def dimension(value, max) do
    {:error, "must be an even integer in 2..#{max}, got #{inspect(value)}"}
  end

  @doc false
  @spec framerate(term()) :: {:ok, [pos_integer()]} | {:error, String.t()}
  def framerate(value) when is_integer(value) and value > 0 and value <= @max_fps do
    {:ok, [value, 1]}
  end

  def framerate([num, den]) when is_integer(num) and is_integer(den) do
    if den > 0 and num >= den and num <= @max_fps * den and num <= @max_timebase and
         den <= @max_timebase,
       do: {:ok, [num, den]},
       else: framerate_error([num, den])
  end

  def framerate(value), do: framerate_error(value)

  defp framerate_error(value) do
    {:error,
     "must be an integer in 1..#{@max_fps}, or [numerator, denominator] whose ratio is in " <>
       "1..#{@max_fps} and whose parts fit in 32 bits, got #{inspect(value)}"}
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
    error in RuntimeError -> {:error, "#{@scope}: #{Exception.message(error)}"}
  end

  defp default_gop([num, den]), do: max(1, round(@gop_seconds * num / den))
end
