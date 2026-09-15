defmodule StreamDoctor.Metric do
  @moduledoc """
  A metric is a fold over timestamped events. `observed_at` is the monotonic
  millisecond clock of the probe that decoded the event, `pts` the media
  timestamp as `Membrane.Time` (or nil).
  """

  @type state :: term()
  @type event ::
          {:video_frame_received, frame :: non_neg_integer(), pts :: Membrane.Time.t() | nil,
           observed_at :: integer()}
          | {:audio_symbol_received, symbol :: non_neg_integer(), pts :: Membrane.Time.t() | nil,
             observed_at :: integer()}

  @doc "Key under which `report/1` results appear in summaries."
  @callback name() :: atom()

  @doc "Builds the initial state from the options given in the collector's metric spec."
  @callback init(opts :: keyword()) :: state()

  @doc "Folds one event into the state; called for every event, regardless of kind."
  @callback handle_event(event(), state()) :: state()

  @doc "Current value of the metric; must be JSON-encodable."
  @callback report(state()) :: map()
end
