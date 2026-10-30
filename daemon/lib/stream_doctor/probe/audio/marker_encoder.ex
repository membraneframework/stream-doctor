defmodule StreamDoctor.Probe.Audio.MarkerEncoder do
  @moduledoc """
  Replaces audio with the marker tones (see `StreamDoctor.Probe.Audio.Tone`). Symbol number k
  covers source time k * 30 ms, whatever pts the audio starts at.
  """

  use Membrane.Filter

  alias Membrane.RawAudio
  alias StreamDoctor.Probe.Audio.Tone

  def_input_pad :input, accepted_format: %RawAudio{sample_format: :s16le, channels: 1}
  def_output_pad :output, accepted_format: %RawAudio{sample_format: :s16le, channels: 1}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{position: nil, format: nil, tone: nil, cache: %{}}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    state = %{
      state
      | format: stream_format,
        tone: Tone.new(stream_format.sample_rate),
        cache: %{}
    }

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    sample_rate = state.format.sample_rate
    frames = RawAudio.bytes_to_frames(byte_size(buffer.payload), state.format)

    position = state.position || round(buffer.pts * sample_rate / Membrane.Time.second())

    {iodata, state} = marker_frames(position, frames, state, [])
    buffer = %{buffer | payload: IO.iodata_to_binary(iodata)}

    {[buffer: {:output, buffer}], %{state | position: position + frames}}
  end

  defp marker_frames(_position, 0, state, acc) do
    {Enum.reverse(acc), state}
  end

  defp marker_frames(position, frames, state, acc) do
    symbol_length = RawAudio.bytes_to_frames(Tone.symbol_bytes(state.tone), state.format)
    symbol_number = Integer.mod(Integer.floor_div(position, symbol_length), Tone.max_symbol())
    offset = Integer.mod(position, symbol_length)
    span = min(frames, symbol_length - offset)

    {symbol, state} = cached_symbol(symbol_number, state)
    chunk = binary_part(symbol, offset * 2, span * 2)

    marker_frames(position + span, frames - span, state, [chunk | acc])
  end

  defp cached_symbol(symbol_number, state) do
    case state.cache do
      %{^symbol_number => samples} ->
        {samples, state}

      cache ->
        samples = Tone.symbol_samples(state.tone, symbol_number)
        {samples, %{state | cache: Map.put(cache, symbol_number, samples)}}
    end
  end
end
