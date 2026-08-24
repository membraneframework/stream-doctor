defmodule StreamDoctor.Metric do
  @moduledoc """
  Behaviour for measurement metrics: a metric is a pure fold over a stream of
  timestamped events, kept as `{module, state}` pairs by the session's
  `StreamDoctor.Metric.Collector` process.

  All timestamps (`t`) are `System.monotonic_time(:millisecond)` values
  produced by the event source, so a metric never reads a clock itself and can
  be tested without running pipelines. `pts_ms` is the media timestamp of the
  frame/symbol on the receiver timeline (`nil` when unknown, e.g. for player
  screenshots).

  A metric must ignore events it does not understand (return the state
  unchanged), so new event types can be added without touching existing
  metrics.
  """

  alias StreamDoctor.Metric

  @type state :: term()
  @type event ::
          {:session_started, t :: integer()}
          | {:playlist_ready, t :: integer()}
          | {:video_frame_sent, frame :: non_neg_integer(), t :: integer()}
          | {:video_frame_received, frame :: non_neg_integer(), pts_ms :: number() | nil,
             t :: integer()}
          | {:audio_symbol_received, symbol :: non_neg_integer(), pts_ms :: number() | nil,
             t :: integer()}
          | {:undecoded, :video | :audio, reason :: term(), t :: integer()}

  @doc "Key under which `report/1` results appear in summaries."
  @callback name() :: atom()

  @callback init(opts :: keyword()) :: state()
  @callback handle_event(event(), state()) :: state()

  @doc "Current results as a JSON-encodable map."
  @callback report(state()) :: map()

  @registry %{
    "latency" => Metric.Latency,
    "ttff" => Metric.TimeToFirstFrame,
    "av_drift" => Metric.AvDrift
  }

  @doc "All registered metric names (JSON API spelling)."
  @spec names() :: [String.t()]
  def names(), do: Map.keys(@registry)

  @doc """
  Resolves a list of metric names from the API into `{module, opts}` specs.
  `nil` selects all registered metrics.
  """
  @spec resolve([String.t()] | nil) ::
          {:ok, [{module(), keyword()}]} | {:error, {:unknown_metric, term()}}
  def resolve(nil), do: {:ok, Enum.map(Map.values(@registry), &{&1, []})}

  def resolve(names) when is_list(names) do
    specs =
      Enum.map(names, fn name ->
        case @registry[name] do
          nil -> {:error, name}
          module -> {module, []}
        end
      end)

    case Enum.find(specs, &match?({:error, _name}, &1)) do
      {:error, name} -> {:error, {:unknown_metric, name}}
      nil -> {:ok, specs}
    end
  end

  def resolve(other), do: {:error, {:unknown_metric, other}}

  ## Helpers for metric owners

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
