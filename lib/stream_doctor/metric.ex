defmodule StreamDoctor.Metric do
  @moduledoc """
  A metric is a fold over timestamped events. `t` is monotonic ms from the
  event source, `pts_ms` the media timestamp (or nil).
  """

  @type state :: term()
  @type event ::
          {:video_frame_received, frame :: non_neg_integer(), pts_ms :: number() | nil,
           t :: integer()}
          | {:audio_symbol_received, symbol :: non_neg_integer(), pts_ms :: number() | nil,
             t :: integer()}

  @doc "Key under which `report/1` results appear in summaries."
  @callback name() :: atom()
  @callback init(opts :: keyword()) :: state()
  @callback handle_event(event(), state()) :: state()
  @doc "JSON-encodable."
  @callback report(state()) :: map()

  @spec init_all([{module(), keyword()}]) :: [{module(), state()}]
  def init_all(specs), do: Enum.map(specs, fn {module, opts} -> {module, module.init(opts)} end)

  @spec handle_event_all([{module(), state()}], event()) :: [{module(), state()}]
  def handle_event_all(metrics, event) do
    Enum.map(metrics, fn {module, state} -> {module, module.handle_event(event, state)} end)
  end

  @spec report_all([{module(), state()}]) :: map()
  def report_all(metrics) do
    Map.new(metrics, fn {module, state} -> {module.name(), module.report(state)} end)
  end
end
