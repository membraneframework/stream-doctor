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

  alias StreamDoctor.Native

  @opaque tone :: reference()

  @spec new(pos_integer()) :: tone()
  defdelegate new(sample_rate), to: Native, as: :tone_new

  @doc "Mixes one symbol into a symbol-length buffer of mono s16le samples."
  @spec encode(binary(), tone(), non_neg_integer()) :: binary()
  defdelegate encode(payload, tone, symbol_number), to: Native, as: :tone_encode

  @symbol_ms 30
  @data_bits 7
  @max_symbol 1 <<< @data_bits

  @ref_freq 500
  @data_freqs Enum.map(1..@data_bits, &(500 + &1 * 500))
  @parity_freq 4500

  @amplitude 3000

  @scan_symbols 6

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
    case Native.tone_find_alignment(buffer, new(sample_rate)) do
      {:ok, offset} -> {:ok, offset}
      {:error, :markers_not_found} -> :error
    end
  end

  @doc "Window = symbol-length binary of f64le mono samples."
  @spec decode_window(binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  def decode_window(window, sample_rate) do
    Native.tone_decode(window, new(sample_rate))
  end

  @spec encode(non_neg_integer()) :: [0 | 1]
  defp encode(symbol_number) do
    n = rem(symbol_number, @max_symbol)
    data = for i <- (@data_bits - 1)..0//-1, do: n >>> i &&& 1
    parity = rem(Enum.sum(data), 2)
    data ++ [parity]
  end
end
