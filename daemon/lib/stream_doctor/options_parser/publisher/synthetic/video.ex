defmodule StreamDoctor.OptionsParser.Publisher.Synthetic.Video do
  @moduledoc """
  Parses the video settings of a synthetic input.
  """

  alias StreamDoctor.OptionsParser.Options

  @type profile :: :baseline | :main | :high

  @type preset ::
          :ultrafast
          | :superfast
          | :veryfast
          | :faster
          | :fast
          | :medium
          | :slow
          | :slower
          | :veryslow
          | :placebo

  @type tune :: :film | :animation | :grain | :stillimage | :fastdecode | :zerolatency

  @type t :: %{
          width: 2..7680,
          height: 2..4320,
          fps: [pos_integer()],
          gop_size: 1..2_147_483_647,
          preset: preset(),
          tune: tune(),
          profile: profile() | nil,
          crf: 0..51 | nil,
          bitrate: 1_000..50_000_000 | nil
        }

  @scope "synthetic.video"

  @max_width 7680
  @max_height 4320
  @max_fps 240

  @gop_seconds 2

  # the H264 encoder passes gop_size and the framerate pair to the NIF as C ints
  @nif_int_max 2_147_483_647

  # the generator emits 8-bit I420, so the 10-bit and 4:2:2/4:4:4 profiles would encode as high
  @profiles ~w(baseline main high)a

  # x264 caps crf at 51 for 8-bit samples and silently clamps anything above it
  @max_crf 51

  @presets ~w(ultrafast superfast veryfast faster fast medium slow slower veryslow placebo)a

  @tunes ~w(film animation grain stillimage fastdecode zerolatency)a

  defp schema do
    [
      width: [type: {:custom, __MODULE__, :dimension, [@max_width]}, default: 640],
      height: [type: {:custom, __MODULE__, :dimension, [@max_height]}, default: 360],
      fps: [type: {:custom, __MODULE__, :framerate, []}, default: 30],
      gop_size: [type: {:in, 1..@nif_int_max}],
      preset: [type: {:in, @presets}, default: :veryfast],
      tune: [type: {:in, @tunes}, default: :zerolatency],
      profile: [type: {:in, @profiles}],
      crf: [type: {:in, 0..@max_crf}],
      bitrate: [type: {:in, 1_000..50_000_000}]
    ]
  end

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) do
    with {:ok, video} <- Options.validate(config, schema(), @scope) do
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
    if den > 0 and num >= den and num <= @max_fps * den and num <= @nif_int_max and
         den <= @nif_int_max,
       do: {:ok, [num, den]},
       else: framerate_error([num, den])
  end

  def framerate(value), do: framerate_error(value)

  defp framerate_error(value) do
    {:error,
     "must be an integer in 1..#{@max_fps}, or [numerator, denominator] whose ratio is in " <>
       "1..#{@max_fps} and whose parts fit in 32 bits, got #{inspect(value)}"}
  end

  defp default_gop([num, den]), do: max(1, round(@gop_seconds * num / den))
end
