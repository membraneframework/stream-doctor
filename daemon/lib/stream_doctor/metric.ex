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
          | {:first_segment_seen, at_ms :: integer()}

  @doc "Timebase of the `at_ms` fields above, shared by everything that stamps an event."
  @spec now_ms() :: integer()
  def now_ms do
    System.monotonic_time(:millisecond)
  end

  @doc "Key under which `report/1` results appear in summaries."
  @callback name() :: atom()

  @doc "Builds the initial state from the options given in the collector's metric spec."
  @callback init(opts :: keyword()) :: state()

  @doc "Folds one event into the state. Called for every event."
  @callback handle_event(event(), state()) :: state()

  @doc "Current value of the metric. Must be JSON-encodable."
  @callback report(state()) :: map()
end
