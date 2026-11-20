defmodule StreamDoctor.Restarter do
  @moduledoc """
  Runs `child` and starts it again `delay_ms` after each crash, up to `max_restarts` times, then
  exits with the reason the child exited with.
  """

  use GenServer, restart: :temporary

  @spec start_link(
          child: Supervisor.child_spec() | {module(), term()} | module(),
          max_restarts: non_neg_integer(),
          delay_ms: non_neg_integer()
        ) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, start(%{child: opts.child, restarts_left: opts.max_restarts, delay_ms: opts.delay_ms})}
  end

  @impl true
  def handle_info({:EXIT, _child, reason}, %{restarts_left: left} = state)
      when left > 0 and reason not in [:normal, :shutdown] do
    Process.send_after(self(), :restart, state.delay_ms)
    {:noreply, %{state | restarts_left: left - 1}}
  end

  @impl true
  def handle_info({:EXIT, _child, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def handle_info(:restart, state) do
    {:noreply, start(state)}
  end

  defp start(state) do
    %{start: {module, function, args}} = Supervisor.child_spec(state.child, [])

    case apply(module, function, args) do
      {:ok, _pid} -> state
      {:ok, _pid, _info} -> state
    end
  end
end
