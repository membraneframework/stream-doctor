defmodule StreamDoctor.Probe.Audio.Tone do
  @moduledoc false

  # Audio marker: 30 ms symbols, number wraps at 128. 500 Hz = always-on ref,
  # 1000..4000 Hz = 7 bits MSB first, 4500 Hz = parity. All multiples of
  # 33.3 Hz so symbols toggle without clicks. Decoding = Goertzel over the
  # inner 2/3 of the window, each tone judged against the guard bins ±250 Hz
  # around it (local SNR, survives spectral tilt from codecs).

  import Bitwise

  @symbol_ms 30
  @data_bits 7
  @max_symbol 1 <<< @data_bits

  @ref_freq 500
  @data_freqs Enum.map(1..@data_bits, &(500 + &1 * 500))
  @parity_freq 4500
  @guard_offset 250

  @amplitude 3000

  @local_contrast 8.0
  @ref_floor 0.01

  @spec max_symbol() :: pos_integer()
  def max_symbol, do: @max_symbol

  @spec symbol_ms() :: pos_integer()
  def symbol_ms, do: @symbol_ms

  @spec symbol_length(pos_integer()) :: pos_integer()
  def symbol_length(sample_rate), do: div(sample_rate * @symbol_ms, 1000)

  @doc "One symbol as mono s16le."
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

  @doc "Window = symbol-length binary of f64le mono samples."
  @spec decode_window(binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :marker_not_found | :parity_mismatch}
  def decode_window(window, sample_rate) do
    n = symbol_length(sample_rate)
    margin = div(n, 6)
    inner_n = n - 2 * margin
    inner = binary_part(window, margin * 8, inner_n * 8)

    power = fn freq -> goertzel_power(inner, inner_n, freq, sample_rate) end

    tone_freqs = [@ref_freq | @data_freqs] ++ [@parity_freq]

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
      bits = Enum.map(@data_freqs ++ [@parity_freq], &tone_bit(&1, power, local_noise, ref_power))
      {data, [parity]} = Enum.split(bits, @data_bits)

      if rem(Enum.sum(data), 2) == parity,
        do: {:ok, Integer.undigits(data, 2)},
        else: {:error, :parity_mismatch}
    end
  end

  defp tone_bit(freq, power, local_noise, ref_power) do
    tone_power = power.(freq)

    if tone_power > @local_contrast * local_noise.(freq) and tone_power > @ref_floor * ref_power,
      do: 1,
      else: 0
  end

  @spec encode(non_neg_integer()) :: [0 | 1]
  defp encode(symbol_number) do
    n = rem(symbol_number, @max_symbol)
    data = for i <- (@data_bits - 1)..0//-1, do: n >>> i &&& 1
    parity = rem(Enum.sum(data), 2)
    data ++ [parity]
  end

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
