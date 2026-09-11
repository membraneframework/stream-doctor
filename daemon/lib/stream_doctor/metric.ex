defmodule StreamDoctor.Metric do
  @moduledoc """
  A metric is a fold over timestamped events. `t` is monotonic ms from the
  event source, `pts` the media timestamp as `Membrane.Time` (or nil).
  """

  @type state :: term()
  @type event ::
          {:video_frame_received, frame :: non_neg_integer(), pts :: Membrane.Time.t() | nil,
           t :: integer()}
          | {:audio_symbol_received, symbol :: non_neg_integer(), pts :: Membrane.Time.t() | nil,
             t :: integer()}

  @doc "Key under which `report/1` results appear in summaries."
  @callback name() :: atom()
  @callback init(opts :: keyword()) :: state()
  @callback handle_event(event(), state()) :: state()
  @doc "JSON-encodable."
  @callback report(state()) :: map()
end
