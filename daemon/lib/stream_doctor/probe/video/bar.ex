defmodule StreamDoctor.Probe.Video.Bar do
  @moduledoc false

  alias StreamDoctor.Native

  @opaque t :: reference()

  @spec max_frame() :: pos_integer()
  defdelegate max_frame(), to: Native, as: :bar_max_frame

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(width, height) do
    case Native.bar_new(width, height) do
      {:ok, bar} -> bar
      {:error, message} -> raise message
    end
  end

  @spec encode(binary(), t(), non_neg_integer()) :: binary()
  defdelegate encode(payload, bar, frame_number), to: Native, as: :bar_encode

  @spec decode(binary(), t()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  defdelegate decode(payload, bar), to: Native, as: :bar_decode
end
