defmodule StreamDoctor.Probe.Video.Bar do
  @moduledoc false

  # Thin wrapper over `stream_doctor_core::bar` (stream_doctor_core/src/bar.rs), see native/stream_doctor_core_nif.

  use Rustler, otp_app: :stream_doctor, crate: :stream_doctor_core_nif

  import Bitwise

  # mirrors DATA_BITS in stream_doctor_core/src/bar.rs, which is not exported
  @data_bits 14
  @max_frame 1 <<< @data_bits

  @opaque geometry :: reference()

  @spec max_frame() :: pos_integer()
  def max_frame do
    @max_frame
  end

  @spec geometry(pos_integer(), pos_integer()) :: geometry()
  def geometry(_width, _height), do: :erlang.nif_error(:nif_not_loaded)

  @spec encode(binary(), geometry(), non_neg_integer()) :: binary()
  def encode(_payload, _geometry, _frame_number), do: :erlang.nif_error(:nif_not_loaded)

  @spec decode(binary(), geometry()) ::
          {:ok, non_neg_integer()} | {:error, :markers_not_found | :parity_mismatch}
  def decode(_payload, _geometry), do: :erlang.nif_error(:nif_not_loaded)
end
