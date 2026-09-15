defmodule StreamDoctor.Probe.Audio.Tone do
  @moduledoc false

  # This module was vibe-coded: the signal design and the decoder were written by an LLM and
  # tuned by trial against real streams, not derived from a reference.

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

  @scan_symbols 6
  @scan_min_score 10

  @spec max_symbol() :: pos_integer()
  def max_symbol do
    @max_symbol
  end

  @spec symbol_ms() :: pos_integer()
  def symbol_ms do
    @symbol_ms
  end

  @spec symbol_length(pos_integer()) :: pos_integer()
  def symbol_length(sample_rate) do
    div(sample_rate * @symbol_ms, 1000)
  end

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

  @doc "Symbols a buffer must hold for `find_alignment/2`. One more than are scored, since the offset sweep reaches into the next symbol."
  @spec alignment_buffer_symbols() :: pos_integer()
  def alignment_buffer_symbols do
    @scan_symbols + 1
  end

  @doc "Sample offset of the symbol boundary in a buffer of `alignment_buffer_symbols/0` symbols, if any."
  @spec find_alignment(binary(), pos_integer()) :: {:ok, non_neg_integer()} | :error
  def find_alignment(buffer, sample_rate) do
    symbol_length = symbol_length(sample_rate)
    step = max(div(symbol_length, 16), 1)

    scores =
      Enum.map(0..(symbol_length - 1)//step, fn offset ->
        {offset, alignment_score(buffer, offset, sample_rate)}
      end)

    best_score = scores |> Enum.map(fn {_offset, score} -> score end) |> Enum.max()

    if best_score >= @scan_min_score,
      do: {:ok, plateau_center(scores, best_score)},
      else: :error
  end

  defp alignment_score(buffer, offset, sample_rate) do
    symbol_bytes = symbol_length(sample_rate) * 8

    results =
      Enum.map(0..(@scan_symbols - 1), fn i ->
        buffer
        |> binary_part(offset * 8 + i * symbol_bytes, symbol_bytes)
        |> decode_window(sample_rate)
      end)

    parity_score = Enum.count(results, &match?({:ok, _n}, &1))

    sequence_score =
      results
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn
        [{:ok, a}, {:ok, b}] -> rem(a + 1, @max_symbol) == b
        _other -> false
      end)

    parity_score + 2 * sequence_score
  end

  # Decoding tolerates a few ms of misalignment, so the top score spans a plateau
  # (possibly straddling the wrap) and the boundary is its middle.
  defp plateau_center(scores, best_score) do
    best? = fn {_offset, score} -> score == best_score end
    rotation = Enum.find_index(scores, &(not best?.(&1))) || 0
    {head, tail} = Enum.split(scores, rotation)

    {offset, _score} =
      (tail ++ head)
      |> Enum.chunk_by(best?)
      |> Enum.filter(&best?.(hd(&1)))
      |> Enum.max_by(&length/1)
      |> then(&Enum.at(&1, div(length(&1), 2)))

    offset
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

  defp goertzel_loop(<<sample::float-64-little, rest::binary>>, coeff, s1, s2) do
    goertzel_loop(rest, coeff, sample + coeff * s1 - s2, s1)
  end

  defp goertzel_loop(<<>>, _coeff, s1, s2) do
    {s1, s2}
  end
end
