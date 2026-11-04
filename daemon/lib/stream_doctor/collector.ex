defmodule StreamDoctor.Collector do
  @moduledoc """
  One collector per viewer. Holds `StreamDoctor.Metric`s, folds events into them and answers
  reports.
  """

  use GenServer

  alias StreamDoctor.Metric

  @spec start_link([{module(), keyword()}]) :: GenServer.on_start()
  def start_link(metric_specs) do
    GenServer.start_link(__MODULE__, metric_specs)
  end

  @spec record(pid(), Metric.event()) :: :ok
  def record(collector, event) do
    GenServer.cast(collector, {:record, event})
  end

  @spec report(pid()) :: map()
  def report(collector) do
    GenServer.call(collector, :report)
  end

  @impl true
  def init(metric_specs) do
    {:ok, Enum.map(metric_specs, fn {module, opts} -> {module, module.new(opts)} end)}
  end

  @impl true
  def handle_cast({:record, event}, metrics) do
    {:noreply, Enum.map(metrics, fn {module, state} -> {module, module.record(event, state)} end)}
  end

  @impl true
  def handle_call(:report, _from, metrics) do
    {:reply, Map.new(metrics, fn {module, state} -> {module.name(), module.report(state)} end),
     metrics}
  end
end
