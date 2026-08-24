defmodule StreamDoctor.Metric.Collector do
  @moduledoc """
  Per-session metric process: owns the `{module, state}` instances of one
  measurement session (an HLS viewer or a screenshot player), folds reported
  events into them and serves reports on demand.

  Probes report here directly: session-scoped events via `event/2`
  (asynchronous, so a busy collector never backpressures a pipeline), and the
  streamer's send events via `broadcast_send_event/1`, which dispatches to
  every collector subscribed in `StreamDoctor.Registry`. Keeping the folds
  out of `StreamDoctor.Server` means per-frame event floods don't queue
  behind lifecycle calls, and a misbehaving metric takes down only its own
  session.
  """

  use GenServer

  alias StreamDoctor.Metric

  @registry StreamDoctor.Registry
  @send_events_key :send_events

  @spec start_link([{module(), keyword()}]) :: GenServer.on_start()
  def start_link(metric_specs) do
    GenServer.start_link(__MODULE__, metric_specs)
  end

  @doc "Reports a session-scoped event (asynchronous)."
  @spec event(pid(), Metric.event()) :: :ok
  def event(collector, event), do: GenServer.cast(collector, {:event, event})

  @doc """
  Reports an event and returns the updated reports in one step - for the
  screenshot endpoint, whose HTTP response includes the resulting metric.
  """
  @spec event_and_report(pid(), Metric.event()) :: map()
  def event_and_report(collector, event) do
    GenServer.call(collector, {:event_and_report, event})
  end

  @doc "Current reports of all metrics, keyed by metric name."
  @spec report(pid()) :: map()
  def report(collector), do: GenServer.call(collector, :report)

  @doc """
  Dispatches a send event to every collector. Called from the sender
  pipeline's probe process; asynchronous.
  """
  @spec broadcast_send_event(Metric.event()) :: :ok
  def broadcast_send_event(event) do
    Registry.dispatch(@registry, @send_events_key, fn entries ->
      for {pid, _value} <- entries, do: GenServer.cast(pid, {:event, event})
    end)
  end

  @doc """
  Subscribes the calling process to the send events: each broadcast arrives
  as a `{:event, event}` cast. Used by every collector, and by
  `StreamDoctor.Server` for its `frames_sent` counter.
  """
  @spec subscribe_send_events() :: :ok
  def subscribe_send_events() do
    {:ok, _owner} = Registry.register(@registry, @send_events_key, nil)
    :ok
  end

  @impl true
  def init(metric_specs) do
    :ok = subscribe_send_events()
    {:ok, Metric.init_all(metric_specs)}
  end

  @impl true
  def handle_cast({:event, event}, metrics) do
    {:noreply, Metric.handle_event_all(metrics, event)}
  end

  @impl true
  def handle_call(:report, _from, metrics) do
    {:reply, Metric.report_all(metrics), metrics}
  end

  @impl true
  def handle_call({:event_and_report, event}, _from, metrics) do
    metrics = Metric.handle_event_all(metrics, event)
    {:reply, Metric.report_all(metrics), metrics}
  end
end
