defmodule StreamDoctor.Metric.Collector do
  @moduledoc "One per viewer; holds the metrics, folds events in, answers reports."

  use GenServer

  alias StreamDoctor.Metric

  @spec start_link([{module(), keyword()}]) :: GenServer.on_start()
  def start_link(metric_specs), do: GenServer.start_link(__MODULE__, metric_specs)

  @spec event(pid(), Metric.event()) :: :ok
  def event(collector, event), do: GenServer.cast(collector, {:event, event})

  @spec report(pid()) :: map()
  def report(collector), do: GenServer.call(collector, :report)

  @impl true
  def init(metric_specs), do: {:ok, Metric.init_all(metric_specs)}

  @impl true
  def handle_cast({:event, event}, metrics),
    do: {:noreply, Metric.handle_event_all(metrics, event)}

  @impl true
  def handle_call(:report, _from, metrics), do: {:reply, Metric.report_all(metrics), metrics}
end
