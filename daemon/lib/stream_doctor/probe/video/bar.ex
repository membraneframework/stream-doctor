defmodule StreamDoctor.Probe.Video.Bar do
  @moduledoc false

  alias StreamDoctor.Native

  @opaque geometry :: reference()

  @spec max_frame() :: pos_integer()
  defdelegate max_frame(), to: Native, as: :bar_max_frame

  @spec geometry(pos_integer(), pos_integer()) :: geometry()
  def geometry(width, height) do
    case Native.bar_geometry(width, height) do
      {:ok, geometry} -> geometry
      {:error, message} -> raise message
    end
  end

  @spec encode(binary(), geometry(), non_neg_integer()) :: binary()
  defdelegate encode(payload, geometry, frame_number), to: Native, as: :bar_encode

  @spec decode(binary(), geometry()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  defdelegate decode(payload, geometry), to: Native, as: :bar_decode
end
