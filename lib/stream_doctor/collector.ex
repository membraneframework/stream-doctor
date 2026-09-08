defmodule StreamDoctor.Collector do
  @moduledoc "One per viewer; holds `StreamDoctor.Metric`s, folds events in, answers reports."

  use GenServer

  alias StreamDoctor.Metric

  @spec start_link([{module(), keyword()}]) :: GenServer.on_start()
  def start_link(metric_specs), do: GenServer.start_link(__MODULE__, metric_specs)

  @spec event(pid(), Metric.event()) :: :ok
  def event(collector, event), do: GenServer.cast(collector, {:event, event})

  @spec report(pid()) :: map()
  def report(collector), do: GenServer.call(collector, :report)

  @impl true
  def init(metric_specs) do
    {:ok, Enum.map(metric_specs, fn {module, opts} -> {module, module.init(opts)} end)}
  end

  @impl true
  def handle_cast({:event, event}, metrics) do
    {:noreply,
     Enum.map(metrics, fn {module, state} -> {module, module.handle_event(event, state)} end)}
  end

  @impl true
  def handle_call(:report, _from, metrics) do
    {:reply, Map.new(metrics, fn {module, state} -> {module.name(), module.report(state)} end),
     metrics}
  end
end
