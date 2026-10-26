defmodule StreamDoctor.Probe.Video.Bar do
  @moduledoc false

  use Rustler, otp_app: :stream_doctor, crate: :stream_doctor_native_nif

  @opaque geometry :: reference()

  @spec max_frame() :: pos_integer()
  def max_frame, do: :erlang.nif_error(:nif_not_loaded)

  @spec geometry(pos_integer(), pos_integer()) :: geometry()
  def geometry(width, height) do
    case geometry_native(width, height) do
      {:ok, geometry} -> geometry
      {:error, message} -> raise message
    end
  end

  defp geometry_native(_width, _height), do: :erlang.nif_error(:nif_not_loaded)

  @spec encode(binary(), geometry(), non_neg_integer()) :: binary()
  def encode(_payload, _geometry, _frame_number), do: :erlang.nif_error(:nif_not_loaded)

  @spec decode(binary(), geometry()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  def decode(_payload, _geometry), do: :erlang.nif_error(:nif_not_loaded)
end
