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

  @max_error_streak 8

  @typep state :: %{
           collector: pid() | nil,
           format: RawAudio.t() | nil,
           tone: Tone.t() | nil,
           buffer: binary(),
           synced?: boolean(),
           error_streak: non_neg_integer(),
           anchor_pts: Membrane.Time.t() | nil,
           appended_samples: non_neg_integer()
         }

  def_input_pad :input, accepted_format: %RawAudio{sample_format: :s16le, channels: 1}

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
      tone: nil,
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
        tone: Tone.new(stream_format.sample_rate),
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
        appended_samples:
          state.appended_samples +
            RawAudio.bytes_to_frames(byte_size(buffer.payload), state.format)
    }

    {[], process(state)}
  end

  @spec process(state()) :: state()
  defp process(state) do
    symbol_bytes = Tone.symbol_bytes(state.tone)

    cond do
      not state.synced? and
          byte_size(state.buffer) >= Tone.alignment_buffer_symbols() * symbol_bytes ->
        state |> synchronize(symbol_bytes) |> process()

      state.synced? and byte_size(state.buffer) >= symbol_bytes ->
        state |> decode_symbol(symbol_bytes) |> process()

      true ->
        state
    end
  end

  @spec synchronize(state(), pos_integer()) :: state()
  defp synchronize(state, symbol_bytes) do
    case Tone.find_alignment(state.buffer, state.tone) do
      {:ok, offset} ->
        Membrane.Logger.debug("Audio marker alignment found at byte offset #{offset}")
        rest_size = byte_size(state.buffer) - offset
        %{state | buffer: binary_part(state.buffer, offset, rest_size), synced?: true}

      {:error, reason} ->
        Membrane.Logger.debug("Audio marker alignment not found: #{inspect(reason)}")
        rest_size = byte_size(state.buffer) - symbol_bytes
        %{state | buffer: binary_part(state.buffer, symbol_bytes, rest_size)}
    end
  end

  @spec decode_symbol(state(), pos_integer()) :: state()
  defp decode_symbol(state, symbol_bytes) do
    result =
      state.buffer
      |> binary_part(0, symbol_bytes)
      |> Tone.decode(state.tone)

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

  @spec symbol_pts(state()) :: Membrane.Time.t() | nil
  defp symbol_pts(%{anchor_pts: nil}) do
    nil
  end

  defp symbol_pts(state) do
    consumed_samples =
      state.appended_samples - RawAudio.bytes_to_frames(byte_size(state.buffer), state.format)

    state.anchor_pts + round(consumed_samples * Membrane.Time.second() / state.format.sample_rate)
  end
end
