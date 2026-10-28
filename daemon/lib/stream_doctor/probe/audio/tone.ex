defmodule StreamDoctor.Probe.Audio.Tone do
  @moduledoc false

  # This module was vibe-coded: the signal design and the decoder were written by an LLM and
  # tuned by trial against real streams, not derived from a reference.

  # Audio marker: 30 ms symbols, number wraps at 128. 500 Hz = always-on ref,
  # 1000..4000 Hz = 7 bits MSB first, 4500 Hz = parity. All multiples of
  # 33.3 Hz so symbols toggle without clicks. Decoding = Goertzel over the
  # inner 2/3 of the window, each tone judged against the guard bins ±250 Hz
  # around it (local SNR, survives spectral tilt from codecs).

  alias StreamDoctor.Native

  @opaque tone :: reference()

  @spec new(pos_integer()) :: tone()
  defdelegate new(sample_rate), to: Native, as: :tone_new

  @doc "Mixes one symbol into a symbol-length buffer of mono s16le samples."
  @spec encode(binary(), tone(), non_neg_integer()) :: binary()
  defdelegate encode(payload, tone, symbol_number), to: Native, as: :tone_encode

  @scan_symbols 6

  @spec max_symbol() :: pos_integer()
  defdelegate max_symbol(), to: Native, as: :tone_max_symbol

  @spec symbol_ms() :: pos_integer()
  defdelegate symbol_ms(), to: Native, as: :tone_symbol_ms

  @spec symbol_length(pos_integer()) :: pos_integer()
  def symbol_length(sample_rate) do
    Native.tone_symbol_length(new(sample_rate))
  end

  @doc "One symbol as mono s16le."
  @spec symbol_samples(non_neg_integer(), pos_integer()) :: binary()
  def symbol_samples(symbol_number, sample_rate) do
    silence = :binary.copy(<<0::16>>, symbol_length(sample_rate))
    encode(silence, new(sample_rate), symbol_number)
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

  @doc "Window = symbol-length binary of s16le mono samples."
  @spec decode_window(binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  def decode_window(window, sample_rate) do
    Native.tone_decode(window, new(sample_rate))
  end
end
