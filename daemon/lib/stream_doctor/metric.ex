defmodule StreamDoctor.Metric do
  @moduledoc """
  A metric is a fold over events. `pts` is the media timestamp as `Membrane.Time`, or nil when
  the probe could not determine it.
  """

  @type state :: term()
  @type event ::
          {:video_frame_received, frame_number :: non_neg_integer(),
           pts :: Membrane.Time.t() | nil}
          | {:audio_symbol_received, symbol_number :: non_neg_integer(),
             pts :: Membrane.Time.t() | nil}
          | {:streamer_started, {:watching, at_ms :: integer()} | :missed}
          | {:streamer_connected, at_ms :: integer()}
          | :streamer_failed
          | {:first_frame_arrived, at_ms :: integer()}
          | {:video_frame_sent, frame_number :: non_neg_integer(), at_ms :: integer()}
          | {:segment_available, sequence_number :: non_neg_integer(), at_ms :: integer()}
          | {:playlist_read, at_ms :: integer(),
             {newest_sequence_number :: non_neg_integer(), target_duration_ms :: pos_integer()}
             | :ended
             | :unreadable}
          | {:playlist_requested, status :: pos_integer() | :timeout | :error,
             took_ms :: non_neg_integer()}
          | {:video_chunk_received, sequence_number :: non_neg_integer(),
             pts :: Membrane.Time.t()}

  @doc "Timebase of the `at_ms` fields above, shared by everything that stamps an event."
  @spec now_ms() :: integer()
  def now_ms do
    System.monotonic_time(:millisecond)
  end

  @doc "Continues a counter that wrapped at `max`, assuming it moved by less than half of it."
  @spec unwrap(non_neg_integer(), integer() | nil, pos_integer()) :: integer()
  def unwrap(value, nil, _max) do
    value
  end

  def unwrap(value, last, max) do
    candidate = Integer.floor_div(last, max) * max + value

    cond do
      candidate < last - div(max, 2) -> candidate + max
      candidate > last + div(max, 2) -> candidate - max
      true -> candidate
    end
  end

  @doc "Upper median of `samples`, nil when there are none."
  @spec median([number()]) :: number() | nil
  def median([]) do
    nil
  end

  def median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end

  @doc "Key under which `report/1` results appear in summaries."
  @callback name() :: atom()

  @doc "Builds the initial state from the options given in the collector's metric spec."
  @callback new(opts :: keyword()) :: state()

  @doc "Folds one event into the state. Called for every event."
  @callback record(event(), state()) :: state()

  @doc "Current value of the metric. Must be JSON-encodable."
  @callback report(state()) :: map()
end
