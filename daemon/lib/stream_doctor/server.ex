defmodule StreamDoctor.Server do
  @moduledoc """
  Holds state of the HTTP API session.
  """

  use GenServer

  alias StreamDoctor.Collector
  alias StreamDoctor.Metric

  @hls_timeout 120_000
  @metric_specs [{Metric.AvDrift, []}]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_streamer(String.t(), String.t()) :: {:ok, map()} | {:error, :already_streaming}
  def start_streamer(input, rtmp_url) do
    GenServer.call(__MODULE__, {:start_streamer, input, rtmp_url})
  end

  @spec stop_streamer() :: {:ok, map()} | {:error, :not_found}
  def stop_streamer do
    GenServer.call(__MODULE__, :stop_streamer, 15_000)
  end

  @spec streamer() :: {:ok, map()} | {:error, :not_found}
  def streamer do
    GenServer.call(__MODULE__, :streamer)
  end

  @spec start_viewer(String.t()) :: {:ok, map()}
  def start_viewer(hls_url) do
    GenServer.call(__MODULE__, {:start_viewer, hls_url})
  end

  @spec stop_viewer(String.t()) :: {:ok, map()} | {:error, :not_found}
  def stop_viewer(id) do
    GenServer.call(__MODULE__, {:stop_viewer, id}, 15_000)
  end

  @spec viewer(String.t()) :: {:ok, map()} | {:error, :not_found}
  def viewer(id) do
    GenServer.call(__MODULE__, {:viewer, id})
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{streamer: nil, viewers: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start_streamer, input, rtmp_url}, _from, state) do
    if state.streamer != nil and state.streamer.status == :streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      pid =
        StreamDoctor.SenderPipeline.start_link(input, rtmp_url, on_live: self())

      Process.monitor(pid)

      streamer = %{
        pid: pid,
        input: input,
        rtmp_url: rtmp_url,
        status: :streaming,
        error: nil,
        live: false
      }

      {:reply, {:ok, streamer_summary(streamer)}, %{state | streamer: streamer}}
    end
  end

  @impl true
  def handle_call(:stop_streamer, _from, %{streamer: nil} = state) do
    {:reply, {:error, :not_found}, state}
  end

  @impl true
  def handle_call(:stop_streamer, _from, state) do
    streamer = terminate_pipeline(state.streamer)
    {:reply, {:ok, streamer_summary(streamer)}, %{state | streamer: streamer}}
  end

  @impl true
  def handle_call(:streamer, _from, %{streamer: nil} = state) do
    {:reply, {:error, :not_found}, state}
  end

  @impl true
  def handle_call(:streamer, _from, state) do
    {:reply, {:ok, streamer_summary(state.streamer)}, state}
  end

  @impl true
  def handle_call({:start_viewer, hls_url}, _from, state) do
    id = "viewer-#{state.next_id}"
    server = self()

    spawn_link(fn ->
      try do
        __MODULE__.HLS.await_playlist(hls_url, @hls_timeout)
        send(server, {:playlist_ready, id})
      rescue
        e -> send(server, {:viewer_failed, id, Exception.message(e)})
      end
    end)

    {:ok, collector} = Collector.start_link(@metric_specs)

    viewer = %{
      id: id,
      hls_url: hls_url,
      pid: nil,
      status: :waiting_for_playlist,
      error: nil,
      collector: collector
    }

    state = %{state | viewers: Map.put(state.viewers, id, viewer), next_id: state.next_id + 1}
    {:reply, {:ok, viewer_summary(viewer)}, state}
  end

  @impl true
  def handle_call({:stop_viewer, id}, _from, state) do
    case state.viewers[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      viewer ->
        viewer = terminate_pipeline(viewer)
        state = put_in(state.viewers[id], viewer)
        {:reply, {:ok, viewer_summary(viewer)}, state}
    end
  end

  @impl true
  def handle_call({:viewer, id}, _from, state) do
    case state.viewers[id] do
      nil -> {:reply, {:error, :not_found}, state}
      viewer -> {:reply, {:ok, viewer_summary(viewer)}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      streamer: state.streamer && streamer_summary(state.streamer),
      viewers: state.viewers |> Map.values() |> Enum.map(&viewer_summary/1)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:streamer_live, pid}, %{streamer: %{pid: pid} = streamer} = state) do
    {:noreply, %{state | streamer: %{streamer | live: true}}}
  end

  @impl true
  def handle_info({:streamer_live, _stale_pid}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:playlist_ready, id}, state) do
    case state.viewers[id] do
      %{status: :waiting_for_playlist} = viewer ->
        pid =
          StreamDoctor.ReceiverPipeline.start_link(viewer.hls_url,
            collector: viewer.collector
          )

        Process.monitor(pid)
        {:noreply, put_in(state.viewers[id], %{viewer | pid: pid, status: :receiving})}

      _stopped_or_missing ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:viewer_failed, id, reason}, state) do
    case state.viewers[id] do
      %{status: :waiting_for_playlist} = viewer ->
        {:noreply, put_in(state.viewers[id], %{viewer | status: :failed, error: reason})}

      _stopped_or_missing ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    error = if reason == :normal, do: nil, else: inspect(reason)

    {:noreply, mark_down_pid(state, pid, error)}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp mark_down_pid(%{streamer: %{pid: pid} = streamer} = state, pid, error) do
    %{state | streamer: mark_down(streamer, error)}
  end

  defp mark_down_pid(state, pid, error) do
    case Enum.find(state.viewers, fn {_id, viewer} -> viewer.pid == pid end) do
      {id, viewer} -> put_in(state.viewers[id], mark_down(viewer, error))
      nil -> state
    end
  end

  defp mark_down(%{status: :stopped} = entity, _error) do
    entity
  end

  defp mark_down(entity, error) do
    %{entity | status: :ended, error: error}
  end

  defp terminate_pipeline(%{pid: pid, status: status} = entity)
       when pid != nil and status in [:streaming, :receiving] do
    Membrane.Pipeline.terminate(pid)
    %{entity | status: :stopped}
  end

  defp terminate_pipeline(entity) do
    %{entity | status: :stopped}
  end

  defp streamer_summary(streamer) do
    Map.take(streamer, [:input, :rtmp_url, :status, :error, :live])
  end

  defp viewer_summary(viewer) do
    %{
      id: viewer.id,
      hls_url: viewer.hls_url,
      status: viewer.status,
      error: viewer.error,
      metrics: safe_report(viewer.collector)
    }
  end

  defp safe_report(collector) do
    Collector.report(collector)
  catch
    :exit, _reason -> %{error: "metrics collector down"}
  end
end
