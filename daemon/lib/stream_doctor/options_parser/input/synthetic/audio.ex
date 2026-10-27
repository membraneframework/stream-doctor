defmodule StreamDoctor.OptionsParser.Input.Synthetic.Audio do
  @moduledoc """
  Parses the audio settings of a synthetic input.
  """

  alias StreamDoctor.OptionsParser.Options

  @type profile :: :mpeg4_lc | :mpeg2_lc

  @type sample_rate :: 12_000 | 16_000 | 24_000 | 32_000 | 44_100 | 48_000 | 64_000 | 88_200

  @type t :: %{
          sample_rate: sample_rate(),
          bitrate: 8_000..512_000 | nil,
          profile: profile()
        }

  @scope "synthetic.audio"

  @profiles ~w(mpeg4_lc mpeg2_lc)a

  @sample_rates [12_000, 16_000, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200]

  @spec schema() :: keyword()
  def schema do
    [
      sample_rate: [type: {:in, @sample_rates}, default: 48_000],
      bitrate: [type: {:in, 8_000..512_000}],
      profile: [type: {:in, @profiles}, default: :mpeg4_lc]
    ]
  end

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) do
    with {:ok, audio} <- Options.validate(config, schema(), @scope) do
      {:ok, Map.merge(%{bitrate: nil}, audio)}
    end
  end
end
