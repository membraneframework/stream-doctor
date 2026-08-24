defmodule StreamDoctor.Probe.AudioMarkerDecoder do
  @moduledoc """
  Reads the audio marker (see `StreamDoctor.Probe.Tone`) from raw audio and reports
  the decoded symbol number (one per 30 ms) via the `on_symbol` callback.

  Symbol boundaries in the received stream are not aligned with buffer
  boundaries (AAC encoder priming and segmenting shift the samples), so the
  sink first synchronizes: it scans candidate offsets within one symbol length
  and picks the one where several consecutive windows decode with valid parity
  and consecutive symbol numbers. It resynchronizes after a run of decode
  errors.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias StreamDoctor.Probe.Tone
  alias Membrane.RawAudio

  # Windows examined when scanning for symbol alignment
  @scan_symbols 6
  # Minimal alignment score (parity hit = 1 point, consecutive numbers = 2 points)
  @scan_min_score 10
  # Consecutive decode errors triggering resynchronization
  @max_error_streak 8

  def_input_pad(:input, accepted_format: %RawAudio{sample_format: :s16le})

  def_options(
    on_symbol: [
      spec: ({:ok, non_neg_integer(), number() | nil} | {:error, atom()} -> any()) | nil,
      default: nil,
      description: """
      Called with `{:ok, symbol_number, pts_ms}` (`pts_ms` is the symbol's
      position on the stream timeline in milliseconds - the first buffer's
      presentation timestamp plus the sample offset - or `nil` when the
      stream carries no timestamps) or `{:error, reason}` for each 30 ms
      audio symbol. Defaults to logging the result.
      """
    ]
  )

  @doc "Number of distinct symbol numbers; the marker's symbol counter wraps at this value."
  @spec max_symbol() :: pos_integer()
  defdelegate max_symbol(), to: Tone

  @doc "Duration of one audio symbol in milliseconds."
  @spec symbol_ms() :: pos_integer()
  defdelegate symbol_ms(), to: Tone

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      on_symbol: opts.on_symbol || (&log_result/1),
      format: nil,
      buffer: <<>>,
      synced?: false,
      error_streak: 0,
      # pts of the first buffer + count of mono samples appended since, so a
      # symbol's pts can be derived from its sample offset in the stream
      anchor_pts_ms: nil,
      appended_samples: 0
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    state = %{
      state
      | format: stream_format,
        buffer: <<>>,
        synced?: false,
        anchor_pts_ms: nil,
        appended_samples: 0
    }

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    mono = downmix_to_floats(buffer.payload, state.format.channels)

    anchor_pts_ms =
      cond do
        state.anchor_pts_ms != nil -> state.anchor_pts_ms
        state.appended_samples == 0 and buffer.pts != nil -> Membrane.Time.as_milliseconds(buffer.pts, :round)
        true -> nil
      end

    state = %{
      state
      | buffer: state.buffer <> mono,
        anchor_pts_ms: anchor_pts_ms,
        appended_samples: state.appended_samples + div(byte_size(mono), 8)
    }

    {[], process(state)}
  end

  defp process(state) do
    symbol_bytes = Tone.symbol_length(state.format.sample_rate) * 8

    cond do
      not state.synced? and byte_size(state.buffer) >= (@scan_symbols + 1) * symbol_bytes ->
        state |> synchronize(symbol_bytes) |> process()

      state.synced? and byte_size(state.buffer) >= symbol_bytes ->
        state |> decode_symbol(symbol_bytes) |> process()

      true ->
        state
    end
  end

  defp synchronize(state, symbol_bytes) do
    sample_rate = state.format.sample_rate
    symbol_length = Tone.symbol_length(sample_rate)
    step = max(div(symbol_length, 16), 1)

    {best_offset, best_score} =
      0..(symbol_length - 1)//step
      |> Enum.map(fn offset -> {offset, alignment_score(state.buffer, offset, sample_rate)} end)
      |> Enum.max_by(fn {_offset, score} -> score end)

    if best_score >= @scan_min_score do
      Membrane.Logger.debug(
        "Audio marker alignment found at offset #{best_offset} (score #{best_score})"
      )

      rest_size = byte_size(state.buffer) - best_offset * 8
      %{state | buffer: binary_part(state.buffer, best_offset * 8, rest_size), synced?: true}
    else
      # No alignment in this stretch - slide one symbol and try with more data
      rest_size = byte_size(state.buffer) - symbol_bytes
      %{state | buffer: binary_part(state.buffer, symbol_bytes, rest_size)}
    end
  end

  defp alignment_score(buffer, offset, sample_rate) do
    symbol_bytes = Tone.symbol_length(sample_rate) * 8

    results =
      Enum.map(0..(@scan_symbols - 1), fn i ->
        buffer
        |> binary_part(offset * 8 + i * symbol_bytes, symbol_bytes)
        |> Tone.decode_window(sample_rate)
      end)

    parity_score = Enum.count(results, &match?({:ok, _n}, &1))

    sequence_score =
      results
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn
        [{:ok, a}, {:ok, b}] -> rem(a + 1, Tone.max_symbol()) == b
        _other -> false
      end)

    parity_score + 2 * sequence_score
  end

  defp decode_symbol(state, symbol_bytes) do
    result =
      state.buffer
      |> binary_part(0, symbol_bytes)
      |> Tone.decode_window(state.format.sample_rate)

    result =
      case result do
        {:ok, symbol_number} -> {:ok, symbol_number, symbol_pts_ms(state)}
        {:error, _reason} = error -> error
      end

    state.on_symbol.(result)

    rest_size = byte_size(state.buffer) - symbol_bytes
    state = %{state | buffer: binary_part(state.buffer, symbol_bytes, rest_size)}

    case result do
      {:ok, _n, _pts_ms} ->
        %{state | error_streak: 0}

      {:error, _reason} when state.error_streak + 1 >= @max_error_streak ->
        Membrane.Logger.debug("Audio marker lost, resynchronizing")
        %{state | error_streak: 0, synced?: false}

      {:error, _reason} ->
        %{state | error_streak: state.error_streak + 1}
    end
  end

  # Takes the first channel of interleaved s16le frames as 64-bit floats
  defp downmix_to_floats(payload, channels) do
    skip = (channels - 1) * 2

    for <<sample::16-signed-little, _rest::binary-size(skip) <- payload>>, into: <<>> do
      <<sample * 1.0::float-64-little>>
    end
  end

  # pts of the front of `state.buffer` (= the symbol about to be decoded):
  # anchor pts + the offset of already-consumed samples
  defp symbol_pts_ms(%{anchor_pts_ms: nil}), do: nil

  defp symbol_pts_ms(state) do
    consumed_samples = state.appended_samples - div(byte_size(state.buffer), 8)
    state.anchor_pts_ms + consumed_samples * 1000 / state.format.sample_rate
  end

  defp log_result({:ok, symbol_number, _pts_ms}),
    do: Membrane.Logger.info("Decoded audio symbol: #{symbol_number}")

  defp log_result({:error, reason}),
    do: Membrane.Logger.warning("Failed to decode audio symbol: #{inspect(reason)}")
end
