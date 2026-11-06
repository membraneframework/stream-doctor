defmodule StreamDoctor.Server do
  @moduledoc """
  Holds state of the HTTP API session.
  """

  use GenServer

  alias StreamDoctor.Collector
  alias StreamDoctor.HLS.Description
  alias StreamDoctor.HLS.Watcher
  alias StreamDoctor.Metric
  alias StreamDoctor.OptionsParser.Publisher

  @metric_specs [
    {Metric.AvDrift, []},
    {Metric.TimeToFirstFrame, []},
    {Metric.Frames, []},
    {Metric.MinimalLatency, []}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_streamer(term(), String.t()) ::
          {:ok, map()} | {:error, :already_streaming | {:invalid_input, String.t()}}
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
    with :ok <- idle(state),
         {:ok, parsed} <- parse_input(input) do
      started_at = Metric.now_ms()
      pid = StreamDoctor.SenderPipeline.start_link(parsed, rtmp_url, on_live: self())

      Process.monitor(pid)
      broadcast(state.viewers, {:streamer_started, {:watching, started_at}})

      streamer = %{
        pid: pid,
        input: Publisher.summary(parsed),
        rtmp_url: rtmp_url,
        status: :streaming,
        error: nil,
        live_at: nil
      }

      {:reply, {:ok, streamer_summary(streamer)}, %{state | streamer: streamer}}
    else
      error -> {:reply, error, state}
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
    {:ok, collector} = Collector.start_link(@metric_specs)

    {:ok, watcher} = Watcher.start_link(url: hls_url, notify: {self(), id})

    record_streamer_state(collector, state.streamer)

    Process.monitor(watcher)

    viewer = %{
      id: id,
      hls_url: hls_url,
      pid: nil,
      watcher: watcher,
      status: :waiting_for_playlist,
      error: nil,
      playlist: nil,
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
        Process.exit(viewer.watcher, :shutdown)
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
    live_at = Metric.now_ms()
    broadcast(state.viewers, {:ingest_started, live_at})
    {:noreply, %{state | streamer: %{streamer | live_at: live_at}}}
  end

  @impl true
  def handle_info({:streamer_live, _stale_pid}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:hls, id, event}, state) do
    case state.viewers[id] do
      nil ->
        {:noreply, state}

      viewer ->
        Collector.record(viewer.collector, event)
        {:noreply, put_in(state.viewers[id], start_receiving(viewer, event))}
    end
  end

  @impl true
  def handle_info({:playlist_description, id, playlist}, state) do
    case state.viewers[id] do
      nil -> {:noreply, state}
      _viewer -> {:noreply, put_in(state.viewers[id].playlist, playlist)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.viewers, fn {_id, viewer} -> viewer.watcher == pid end) do
      {id, viewer} ->
        {:noreply, put_in(state.viewers[id], watch_stopped(viewer, reason))}

      nil ->
        {:noreply,
         mark_down_pid(state, pid, if(reason == :normal, do: nil, else: inspect(reason)))}
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp start_receiving(%{status: :waiting_for_playlist} = viewer, {:first_frame_arrived, _at}) do
    pid = StreamDoctor.ReceiverPipeline.start_link(viewer.hls_url, collector: viewer.collector)

    Process.monitor(pid)
    describe_playlist(viewer)

    %{viewer | pid: pid, status: :receiving}
  end

  defp start_receiving(viewer, _event), do: viewer

  defp describe_playlist(viewer) do
    server = self()

    pid =
      spawn(fn ->
        send(server, {:playlist_description, viewer.id, playlist_description(viewer.hls_url)})
      end)

    Process.monitor(pid)
  end

  defp playlist_description(hls_url) do
    case Description.variants(hls_url) do
      {:ok, variants} -> %{variants: variants, error: nil}
      {:error, reason} -> %{variants: [], error: reason}
    end
  end

  defp watch_stopped(viewer, :normal), do: viewer

  defp watch_stopped(%{status: :waiting_for_playlist} = viewer, {:shutdown, reason}) do
    %{viewer | status: :failed, error: reason}
  end

  defp watch_stopped(%{status: :receiving} = viewer, {:shutdown, reason}) do
    %{viewer | error: reason}
  end

  defp watch_stopped(viewer, _stopped_or_ended), do: viewer

  defp mark_down_pid(%{streamer: %{pid: pid} = streamer} = state, pid, error) do
    %{state | streamer: mark_down(streamer, error)}
  end

  defp mark_down_pid(state, pid, error) do
    case Enum.find(state.viewers, fn {_id, viewer} -> viewer.pid == pid end) do
      {id, viewer} ->
        Process.exit(viewer.watcher, :shutdown)
        put_in(state.viewers[id], mark_down(viewer, error))

      nil ->
        state
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

  defp idle(%{streamer: %{status: :streaming}}), do: {:error, :already_streaming}
  defp idle(_state), do: :ok

  defp parse_input(input) do
    case Publisher.parse(input) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp broadcast(viewers, event) do
    viewers
    |> Enum.filter(fn {_id, viewer} -> viewer.status in [:waiting_for_playlist, :receiving] end)
    |> Enum.each(fn {_id, viewer} -> Collector.record(viewer.collector, event) end)
  end

  defp record_streamer_state(collector, streamer) do
    streamer
    |> streamer_events_so_far()
    |> Enum.each(&Collector.record(collector, &1))
  end

  defp streamer_events_so_far(nil), do: []
  defp streamer_events_so_far(%{live_at: nil}), do: [{:streamer_started, :missed}]

  defp streamer_events_so_far(%{live_at: at}),
    do: [{:streamer_started, :missed}, {:ingest_started, at}]

  defp streamer_summary(streamer) do
    streamer
    |> Map.take([:input, :rtmp_url, :status, :error])
    |> Map.put(:live, streamer.live_at != nil)
  end

  defp viewer_summary(viewer) do
    %{
      id: viewer.id,
      hls_url: viewer.hls_url,
      status: viewer.status,
      error: viewer.error,
      playlist: viewer.playlist,
      metrics: safe_report(viewer.collector)
    }
  end

  defp safe_report(collector) do
    Collector.report(collector)
  catch
    :exit, _reason -> %{error: "metrics collector down"}
  end
end
