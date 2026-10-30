defmodule StreamDoctor.Probe.Audio.Tone do
  @moduledoc false

  alias StreamDoctor.Native

  @opaque tone :: reference()

  @spec new(pos_integer()) :: tone()
  defdelegate new(sample_rate), to: Native, as: :tone_new

  @spec encode(binary(), tone(), non_neg_integer()) :: binary()
  defdelegate encode(payload, tone, symbol_number), to: Native, as: :tone_encode

  @spec max_symbol() :: pos_integer()
  defdelegate max_symbol(), to: Native, as: :tone_max_symbol

  @spec symbol_ms() :: pos_integer()
  defdelegate symbol_ms(), to: Native, as: :tone_symbol_ms

  @spec symbol_length(pos_integer()) :: pos_integer()
  def symbol_length(sample_rate) do
    sample_rate |> new() |> Native.tone_symbol_length()
  end

  @spec symbol_samples(non_neg_integer(), pos_integer()) :: binary()
  def symbol_samples(symbol_number, sample_rate) do
    silence = :binary.copy(<<0::16>>, symbol_length(sample_rate))
    encode(silence, new(sample_rate), symbol_number)
  end

  @spec alignment_buffer_symbols() :: pos_integer()
  def alignment_buffer_symbols do
    Native.tone_scan_symbols() + 1
  end

  @spec find_alignment(binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found}
  def find_alignment(buffer, sample_rate) do
    Native.tone_find_alignment(buffer, new(sample_rate))
  end

  @spec decode_window(binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  def decode_window(window, sample_rate) do
    Native.tone_decode(window, new(sample_rate))
  end
end
