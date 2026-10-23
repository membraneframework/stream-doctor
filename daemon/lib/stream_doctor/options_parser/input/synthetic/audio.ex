defmodule StreamDoctor.OptionsParser.Input.Synthetic.Audio do
  @moduledoc """
  Parses the audio settings of a synthetic input.
  """

  alias StreamDoctor.OptionsParser.Validate

  @type profile :: :mpeg4_lc | :mpeg2_lc

  @type sample_rate :: 12_000 | 16_000 | 24_000 | 32_000 | 44_100 | 48_000 | 64_000 | 88_200

  @type t :: %{
          sample_rate: sample_rate(),
          bitrate: 8_000..512_000 | nil,
          profile: profile()
        }

  @profiles ~w(mpeg4_lc mpeg2_lc)a

  @sample_rates [12_000, 16_000, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200]

  @keys ~w(sample_rate bitrate profile)

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) when is_map(config) do
    with :ok <- Validate.known_keys(config, @keys, "synthetic.audio"),
         {:ok, sample_rate} <- sample_rate(config),
         {:ok, bitrate} <-
           Validate.optional_int(config, "bitrate", 8_000..512_000, "synthetic.audio"),
         {:ok, profile} <- Validate.member(config, "profile", @profiles, "synthetic.audio") do
      {:ok, %{sample_rate: sample_rate, bitrate: bitrate, profile: profile || :mpeg4_lc}}
    end
  end

  def parse(_other), do: {:error, "synthetic.audio must be an object"}

  defp sample_rate(config) do
    case Map.get(config, "sample_rate", 48_000) do
      value when value in @sample_rates ->
        {:ok, value}

      value ->
        {:error,
         "synthetic.audio.sample_rate must be one of #{Validate.list(@sample_rates)}, " <>
           "got #{inspect(value)}"}
    end
  end
end
