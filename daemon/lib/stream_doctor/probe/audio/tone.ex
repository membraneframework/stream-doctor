defmodule StreamDoctor.Probe.Audio.Tone do
  @moduledoc false

  alias StreamDoctor.Native

  @opaque t :: reference()

  @spec new(pos_integer()) :: t()
  defdelegate new(sample_rate), to: Native, as: :tone_new

  @spec max_symbol() :: pos_integer()
  defdelegate max_symbol(), to: Native, as: :tone_max_symbol

  @spec symbol_ms() :: pos_integer()
  defdelegate symbol_ms(), to: Native, as: :tone_symbol_ms

  @spec symbol_bytes(t()) :: pos_integer()
  defdelegate symbol_bytes(tone), to: Native, as: :tone_symbol_bytes

  @spec alignment_buffer_symbols() :: pos_integer()
  def alignment_buffer_symbols do
    Native.tone_scan_symbols() + 1
  end

  @spec encode(binary(), t(), non_neg_integer()) :: binary()
  defdelegate encode(payload, tone, symbol_number), to: Native, as: :tone_encode

  @spec symbol_samples(t(), non_neg_integer()) :: binary()
  def symbol_samples(tone, symbol_number) do
    silence = :binary.copy(<<0>>, symbol_bytes(tone))
    encode(silence, tone, symbol_number)
  end

  @spec find_alignment(binary(), t()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found}
  defdelegate find_alignment(buffer, tone), to: Native, as: :tone_find_alignment

  @spec decode(binary(), t()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  defdelegate decode(window, tone), to: Native, as: :tone_decode
end
