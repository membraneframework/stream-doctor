defmodule StreamDoctor.Probe.Audio.MarkerEncoder do
  @moduledoc "Replaces audio with the marker tones (see `StreamDoctor.Probe.Audio.Tone`). Symbol m covers source time m * 30 ms, whatever pts the audio starts at. Replaces, not mixes, so content can't confuse the decoder."

  use Membrane.Filter

  alias Membrane.RawAudio
  alias StreamDoctor.Probe.Audio.Tone

  def_input_pad :input, accepted_format: %RawAudio{sample_format: :s16le}
  def_output_pad :output, accepted_format: %RawAudio{sample_format: :s16le}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{position: nil, format: nil, cache: %{}}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    {[stream_format: {:output, stream_format}], %{state | format: stream_format, cache: %{}}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %{sample_rate: sample_rate, channels: channels} = state.format
    frames = div(byte_size(buffer.payload), 2 * channels)

    position = state.position || round(buffer.pts * sample_rate / Membrane.Time.second())

    {iodata, state} = marker_frames(position, frames, sample_rate, channels, state, [])
    buffer = %{buffer | payload: IO.iodata_to_binary(iodata)}

    {[buffer: {:output, buffer}], %{state | position: position + frames}}
  end

  defp marker_frames(_position, 0, _sample_rate, _channels, state, acc),
    do: {Enum.reverse(acc), state}

  defp marker_frames(position, frames, sample_rate, channels, state, acc) do
    symbol_length = Tone.symbol_length(sample_rate)
    symbol_number = Integer.mod(Integer.floor_div(position, symbol_length), Tone.max_symbol())
    offset = Integer.mod(position, symbol_length)
    span = min(frames, symbol_length - offset)

    {mono_symbol, state} = cached_symbol(symbol_number, sample_rate, state)
    mono_span = binary_part(mono_symbol, offset * 2, span * 2)

    chunk =
      if channels == 1,
        do: mono_span,
        else: for(<<sample::binary-size(2) <- mono_span>>, do: :binary.copy(sample, channels))

    marker_frames(position + span, frames - span, sample_rate, channels, state, [chunk | acc])
  end

  defp cached_symbol(symbol_number, sample_rate, state) do
    case state.cache do
      %{^symbol_number => samples} ->
        {samples, state}

      cache ->
        samples = Tone.symbol_samples(symbol_number, sample_rate)
        {samples, %{state | cache: Map.put(cache, symbol_number, samples)}}
    end
  end
end
