defmodule StreamDoctor.Native do
  @moduledoc false

  use Rustler, otp_app: :stream_doctor, crate: :stream_doctor_native_nif

  def bar_max_frame, do: :erlang.nif_error(:nif_not_loaded)
  def bar_new(_width, _height), do: :erlang.nif_error(:nif_not_loaded)
  def bar_encode(_bar, _payload, _frame_number), do: :erlang.nif_error(:nif_not_loaded)
  def bar_decode(_bar, _payload), do: :erlang.nif_error(:nif_not_loaded)

  def tone_new(_sample_rate), do: :erlang.nif_error(:nif_not_loaded)
  def tone_max_symbol, do: :erlang.nif_error(:nif_not_loaded)
  def tone_symbol_ms, do: :erlang.nif_error(:nif_not_loaded)
  def tone_scan_symbols, do: :erlang.nif_error(:nif_not_loaded)
  def tone_symbol_bytes(_tone), do: :erlang.nif_error(:nif_not_loaded)
  def tone_encode(_tone, _payload, _symbol_number), do: :erlang.nif_error(:nif_not_loaded)
  def tone_find_alignment(_tone, _payload), do: :erlang.nif_error(:nif_not_loaded)
  def tone_decode(_tone, _payload), do: :erlang.nif_error(:nif_not_loaded)
end
