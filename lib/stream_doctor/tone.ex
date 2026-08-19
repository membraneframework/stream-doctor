defmodule StreamDoctor.Tone do
  @moduledoc """
  Encoding and decoding of the audio marker - the audible counterpart of
  `StreamDoctor.Bar`.

  The audio stream is divided into 30 ms symbols. Symbol number `n` (the
  stream timestamp divided by 30 ms, wrapping at #{Integer.pow(2, 7)}) is
  encoded as presence or absence of pure tones:

    * 500 Hz - reference tone, always present (like the reference squares),
    * 1000..4000 Hz every 500 Hz - 7 data bits of the symbol number, MSB first
      (tone present = 1),
    * 4500 Hz - even-parity bit over the data bits.

  All frequencies are multiples of 1/30 ms ≈ 33.3 Hz, so every symbol contains
  a whole number of cycles of each tone - symbols start and end at zero phase
  and can be toggled without clicks, and each tone falls into a single DFT bin
  of a symbol-length window.

  Decoding measures tone powers with the Goertzel algorithm over the inner 2/3
  of the symbol window (to avoid symbol-boundary transitions). Each tone is
  compared against its local noise floor - the guard bins 250 Hz below and
  above it, where nothing is ever emitted - so the decision is a local SNR
  test, robust to spectral tilt (e.g. high-frequency attenuation introduced by
  lossy codecs or filtering). A bit counts as present when its power exceeds
  the louder of its two guard bins several times over and stays above a small
  fraction of the reference power (a sanity floor against near-silent windows).
  The always-on reference tone must pass the same local contrast test for the
  window to count as containing a marker at all.
  """

  import Bitwise

  @symbol_ms 30
  @data_bits 7
  @max_symbol 1 <<< @data_bits

  @ref_freq 500
  @data_freqs Enum.map(1..@data_bits, &(500 + &1 * 500))
  @parity_freq 4500
  # Guard bins halfway between tones; never emitted, they measure the local noise floor
  @guard_offset 250

  # Per-tone amplitude in int16 scale; max 9 simultaneous tones stay below clipping
  @amplitude 3000

  # A tone counts as present above this multiple of its louder neighbouring guard bin
  @local_contrast 8.0
  # ...and above this fraction of the reference power (floor against near-silent windows)
  @ref_floor 0.01

  @doc "Number of distinct symbol numbers; the counter wraps at this value."
  @spec max_symbol() :: pos_integer()
  def max_symbol(), do: @max_symbol

  @doc "Symbol duration in milliseconds."
  @spec symbol_ms() :: pos_integer()
  def symbol_ms(), do: @symbol_ms

  @doc "Symbol length in samples for the given sample rate."
  @spec symbol_length(pos_integer()) :: pos_integer()
  def symbol_length(sample_rate), do: div(sample_rate * @symbol_ms, 1000)

  @doc """
  Generates one symbol of the marker signal as mono s16le samples.
  """
  @spec symbol_samples(non_neg_integer(), pos_integer()) :: binary()
  def symbol_samples(symbol_number, sample_rate) do
    bits = encode(symbol_number)

    active_freqs =
      [
        @ref_freq
        | Enum.zip(@data_freqs ++ [@parity_freq], bits)
          |> Enum.filter(fn {_freq, bit} -> bit == 1 end)
          |> Enum.map(fn {freq, 1} -> freq end)
      ]

    n = symbol_length(sample_rate)
    angular = Enum.map(active_freqs, &(2 * :math.pi() * &1 / sample_rate))

    for i <- 0..(n - 1), into: <<>> do
      value =
        angular
        |> Enum.map(&(:math.sin(&1 * i) * @amplitude))
        |> Enum.sum()
        |> round()
        |> max(-32_768)
        |> min(32_767)

      <<value::16-signed-little>>
    end
  end

  @doc """
  Decodes the symbol number from a symbol-length window of mono samples
  given as a binary of little-endian 64-bit floats.

  Returns `{:ok, symbol_number}`, `{:error, :marker_not_found}` when the
  reference tone doesn't stand out from the noise floor, or
  `{:error, :parity_mismatch}`.
  """
  @spec decode_window(binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :marker_not_found | :parity_mismatch}
  def decode_window(window, sample_rate) do
    n = symbol_length(sample_rate)
    margin = div(n, 6)
    inner_n = n - 2 * margin
    inner = binary_part(window, margin * 8, inner_n * 8)

    power = fn freq -> goertzel_power(inner, inner_n, freq, sample_rate) end

    tone_freqs = [@ref_freq | @data_freqs] ++ [@parity_freq]

    # Guard bins are shared between neighbouring tones - compute each once
    guard_powers =
      tone_freqs
      |> Enum.flat_map(&[&1 - @guard_offset, &1 + @guard_offset])
      |> Enum.uniq()
      |> Map.new(&{&1, power.(&1)})

    local_noise = fn freq ->
      max(guard_powers[freq - @guard_offset], guard_powers[freq + @guard_offset])
    end

    ref_power = power.(@ref_freq)

    if ref_power < @local_contrast * max(local_noise.(@ref_freq), 1.0e-9) do
      {:error, :marker_not_found}
    else
      bits =
        Enum.map(@data_freqs ++ [@parity_freq], fn freq ->
          tone_power = power.(freq)

          present? =
            tone_power > @local_contrast * local_noise.(freq) and
              tone_power > @ref_floor * ref_power

          if present?, do: 1, else: 0
        end)

      {data, [parity]} = Enum.split(bits, @data_bits)

      if rem(Enum.sum(data), 2) == parity,
        do: {:ok, Integer.undigits(data, 2)},
        else: {:error, :parity_mismatch}
    end
  end

  @spec encode(non_neg_integer()) :: [0 | 1]
  defp encode(symbol_number) do
    n = rem(symbol_number, @max_symbol)
    data = for i <- (@data_bits - 1)..0//-1, do: n >>> i &&& 1
    parity = rem(Enum.sum(data), 2)
    data ++ [parity]
  end

  # Power of the DFT bin closest to freq, via the Goertzel algorithm.
  defp goertzel_power(samples, n, freq, sample_rate) do
    k = round(freq * n / sample_rate)
    omega = 2 * :math.pi() * k / n
    coeff = 2 * :math.cos(omega)
    {s1, s2} = goertzel_loop(samples, coeff, 0.0, 0.0)
    s1 * s1 + s2 * s2 - coeff * s1 * s2
  end

  defp goertzel_loop(<<sample::float-64-little, rest::binary>>, coeff, s1, s2),
    do: goertzel_loop(rest, coeff, sample + coeff * s1 - s2, s1)

  defp goertzel_loop(<<>>, _coeff, s1, s2), do: {s1, s2}
end
