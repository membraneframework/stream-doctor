defmodule StreamDoctor.Probe.Audio.MarkerDecoder do
  @moduledoc """
  Reads audio symbols, reports them to a collector (or logs). Self-syncs to symbol boundaries
  since AAC shifts them.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias Membrane.RawAudio
  alias StreamDoctor.Collector
  alias StreamDoctor.Probe.Audio.Tone

  @scan_symbols 6
  @scan_min_score 10
  @max_error_streak 8

  def_input_pad :input, accepted_format: %RawAudio{sample_format: :f64le, channels: 1}

  def_options collector: [
                spec: pid() | nil,
                default: nil,
                description:
                  "Gets `{:audio_symbol_received, symbol_number, pts}`. When nil, events are logged instead."
              ]

  @spec max_symbol() :: pos_integer()
  defdelegate max_symbol(), to: Tone

  @spec symbol_ms() :: pos_integer()
  defdelegate symbol_ms(), to: Tone

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      collector: opts.collector,
      format: nil,
      buffer: <<>>,
      synced?: false,
      error_streak: 0,
      anchor_pts: nil,
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
        anchor_pts: nil,
        appended_samples: 0
    }

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    anchor_pts =
      cond do
        state.anchor_pts != nil -> state.anchor_pts
        state.appended_samples == 0 -> buffer.pts
        true -> nil
      end

    state = %{
      state
      | buffer: state.buffer <> buffer.payload,
        anchor_pts: anchor_pts,
        appended_samples: state.appended_samples + div(byte_size(buffer.payload), 8)
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

    scores =
      Enum.map(0..(symbol_length - 1)//step, fn offset ->
        {offset, alignment_score(state.buffer, offset, sample_rate)}
      end)

    best_score = scores |> Enum.map(fn {_offset, score} -> score end) |> Enum.max()
    best_offset = plateau_center(scores, best_score)

    if best_score >= @scan_min_score do
      Membrane.Logger.debug(
        "Audio marker alignment found at offset #{best_offset} (score #{best_score})"
      )

      rest_size = byte_size(state.buffer) - best_offset * 8
      %{state | buffer: binary_part(state.buffer, best_offset * 8, rest_size), synced?: true}
    else
      rest_size = byte_size(state.buffer) - symbol_bytes
      %{state | buffer: binary_part(state.buffer, symbol_bytes, rest_size)}
    end
  end

  # Decoding tolerates a few ms of misalignment, so the top score spans a
  # plateau (possibly straddling the wrap) and the boundary is its middle.
  defp plateau_center(scores, best_score) do
    best? = fn {_offset, score} -> score == best_score end
    rotation = Enum.find_index(scores, &(not best?.(&1))) || 0
    {head, tail} = Enum.split(scores, rotation)

    {offset, _score} =
      (tail ++ head)
      |> Enum.chunk_by(best?)
      |> Enum.filter(&best?.(hd(&1)))
      |> Enum.max_by(&length/1)
      |> then(&Enum.at(&1, div(length(&1), 2)))

    offset
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

    case {result, state.collector} do
      {{:ok, symbol_number}, nil} ->
        Membrane.Logger.info("Decoded audio symbol: #{symbol_number}")

      {{:error, reason}, nil} ->
        Membrane.Logger.warning("Failed to decode audio symbol: #{inspect(reason)}")

      {{:ok, symbol_number}, collector} ->
        Collector.event(
          collector,
          {:audio_symbol_received, symbol_number, symbol_pts(state)}
        )

      {{:error, reason}, _collector} ->
        Membrane.Logger.debug("Failed to decode audio symbol: #{inspect(reason)}")
    end

    rest_size = byte_size(state.buffer) - symbol_bytes
    state = %{state | buffer: binary_part(state.buffer, symbol_bytes, rest_size)}

    case result do
      {:ok, _n} ->
        %{state | error_streak: 0}

      {:error, _reason} when state.error_streak + 1 >= @max_error_streak ->
        Membrane.Logger.debug("Audio marker lost, resynchronizing")
        %{state | error_streak: 0, synced?: false}

      {:error, _reason} ->
        %{state | error_streak: state.error_streak + 1}
    end
  end

  defp symbol_pts(%{anchor_pts: nil}) do
    nil
  end

  defp symbol_pts(state) do
    consumed_samples = state.appended_samples - div(byte_size(state.buffer), 8)
    state.anchor_pts + round(consumed_samples * Membrane.Time.second() / state.format.sample_rate)
  end
end
