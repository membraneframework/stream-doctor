defmodule StreamDoctor.Native do
  @moduledoc false

  use Rustler, otp_app: :stream_doctor, crate: :stream_doctor_native_nif

  def bar_max_frame, do: :erlang.nif_error(:nif_not_loaded)
  def bar_geometry(_width, _height), do: :erlang.nif_error(:nif_not_loaded)
  def bar_encode(_payload, _geometry, _frame_number), do: :erlang.nif_error(:nif_not_loaded)
  def bar_decode(_payload, _geometry), do: :erlang.nif_error(:nif_not_loaded)

  def tone_new(_sample_rate), do: :erlang.nif_error(:nif_not_loaded)
  def tone_max_symbol, do: :erlang.nif_error(:nif_not_loaded)
  def tone_symbol_ms, do: :erlang.nif_error(:nif_not_loaded)
  def tone_scan_symbols, do: :erlang.nif_error(:nif_not_loaded)
  def tone_symbol_length(_tone), do: :erlang.nif_error(:nif_not_loaded)
  def tone_encode(_payload, _tone, _symbol_number), do: :erlang.nif_error(:nif_not_loaded)
  def tone_find_alignment(_payload, _tone), do: :erlang.nif_error(:nif_not_loaded)
  def tone_decode(_payload, _tone), do: :erlang.nif_error(:nif_not_loaded)
end
