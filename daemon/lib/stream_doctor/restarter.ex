defmodule StreamDoctor.Restarter do
  @moduledoc """
  Runs `child` and starts it again `delay_ms` after each crash, up to `max_restarts` times, then
  exits with the reason the child exited with.

  Both default to zero, and zero restarts means the child is never started again.
  """

  use GenServer, restart: :temporary

  @spec start_link(
          child: Supervisor.child_spec() | {module(), term()} | module(),
          max_restarts: non_neg_integer(),
          delay_ms: non_neg_integer()
        ) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      Keyword.validate!(opts, [:child, max_restarts: 0, delay_ms: 0])
    )
  end

  @doc """
  Returns the pid of the running child. For a child that starts under its own supervisor, like a
  Membrane pipeline, it is the pid reported next to the supervisor's.
  """
  @spec child(pid()) :: pid()
  def child(restarter) do
    GenServer.call(restarter, :child)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{child: opts[:child], restarts_left: opts[:max_restarts], delay_ms: opts[:delay_ms]}
    {:ok, start(state)}
  end

  @impl true
  def handle_call(:child, _from, state) do
    {:reply, state.pid, state}
  end

  @impl true
  def handle_info({:EXIT, _child, reason}, state) do
    crashed? = reason not in [:normal, :shutdown] and not match?({:shutdown, _why}, reason)

    if crashed? and state.restarts_left > 0 do
      Process.send_after(self(), :restart, state.delay_ms)
      {:noreply, %{state | restarts_left: state.restarts_left - 1}}
    else
      {:stop, reason, state}
    end
  end

  @impl true
  def handle_info(:restart, state) do
    {:noreply, start(state)}
  end

  defp start(state) do
    %{start: {module, function, args}} = Supervisor.child_spec(state.child, [])

    case apply(module, function, args) do
      {:ok, pid} -> Map.put(state, :pid, pid)
      {:ok, _supervisor, pid} -> Map.put(state, :pid, pid)
    end
  end
end
