defmodule StreamDoctor.Server do
  @moduledoc """
  Holds measurement state for the HTTP API (`StreamDoctor.Api`): one streamer
  pipeline and any number of viewer pipelines, all running in this BEAM node,
  so a single monotonic clock is shared - no clock synchronization issues.

  All measurement math lives in `StreamDoctor.Metric` implementations; this
  server only manages pipeline lifecycle and routes timestamped events to the
  metric instances held by each viewer and player. Streamer send events are
  fanned out to every viewer's and player's metrics; receive and lifecycle
  events go to their own viewer/player only.

  Viewers join at the live edge and run unpaced, so frames arrive in
  per-segment batches; see `StreamDoctor.Metric.Latency` for how that shapes
  the reported latency.

  Besides HLS viewers there are **players**: external players (e.g. the IVS
  player on a web page) whose frames are screenshot by the client and posted
  to the API, where `StreamDoctor.Probe.ImageMarkerDecoder` decodes the frame number. Their
  latency is `screenshot arrival time - send time` (measured on this node's
  clock; includes the client's capture + upload overhead, typically tens of
  ms), so it is the true "what the player shows right now" latency.
  """

  use GenServer
  require Logger

  alias StreamDoctor.Metric

  @hls_timeout 120_000

  @player_metric_specs [{Metric.Latency, [mode: :latest]}]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_streamer(String.t(), String.t()) :: {:ok, map()} | {:error, :already_streaming}
  def start_streamer(input, rtmp_url) do
    GenServer.call(__MODULE__, {:start_streamer, input, rtmp_url})
  end

  @spec stop_streamer() :: {:ok, map()} | {:error, :not_found}
  def stop_streamer(), do: GenServer.call(__MODULE__, :stop_streamer, 15_000)

  @spec streamer() :: {:ok, map()} | {:error, :not_found}
  def streamer(), do: GenServer.call(__MODULE__, :streamer)

  @doc """
  Starts a viewer with the given metrics (`nil` = all registered, see
  `StreamDoctor.Metric.resolve/1`).
  """
  @spec start_viewer(String.t(), [String.t()] | nil) ::
          {:ok, map()} | {:error, {:unknown_metric, term()}}
  def start_viewer(hls_url, metric_names \\ nil),
    do: GenServer.call(__MODULE__, {:start_viewer, hls_url, metric_names})

  @spec stop_viewer(String.t()) :: {:ok, map()} | {:error, :not_found}
  def stop_viewer(id), do: GenServer.call(__MODULE__, {:stop_viewer, id}, 15_000)

  @spec viewer(String.t()) :: {:ok, map()} | {:error, :not_found}
  def viewer(id), do: GenServer.call(__MODULE__, {:viewer, id})

  @spec status() :: map()
  def status(), do: GenServer.call(__MODULE__, :status)

  @doc """
  Records a player's screenshot decode result (`t` = when the screenshot
  arrived, `System.monotonic_time(:millisecond)`); creates the player entry on
  first use. Returns the JSON-ready response for the API.
  """
  @spec record_player_frame(String.t(), {:ok, non_neg_integer()} | {:error, atom()}, integer()) ::
          map()
  def record_player_frame(id, decode_result, t) do
    GenServer.call(__MODULE__, {:player_frame, id, decode_result, t})
  end

  @spec player(String.t()) :: {:ok, map()} | {:error, :not_found}
  def player(id), do: GenServer.call(__MODULE__, {:player, id})

  ## Callbacks

  @impl true
  def init(_opts) do
    # pipelines are linked to this server; trap exits so a crashing pipeline
    # is recorded as :ended instead of taking the server down
    Process.flag(:trap_exit, true)
    {:ok, %{streamer: nil, viewers: %{}, players: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start_streamer, input, rtmp_url}, _from, state) do
    if state.streamer != nil and state.streamer.status == :streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      server = self()

      pid =
        StreamDoctor.SenderPipeline.start_link(input, rtmp_url,
          realtime?: true,
          on_video_frame_sent: fn n -> GenServer.cast(server, {:frame_sent, n, now_ms()}) end
        )

      Process.monitor(pid)
      streamer = %{pid: pid, input: input, rtmp_url: rtmp_url, status: :streaming, error: nil}
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
  def handle_call({:start_viewer, hls_url, metric_names}, _from, state) do
    case Metric.resolve(metric_names) do
      {:error, _unknown} = error ->
        {:reply, error, state}

      {:ok, metric_specs} ->
        id = "viewer-#{state.next_id}"
        server = self()

        # wait for the playlist off-band so the API call returns immediately;
        # the receiver pipeline is started once the playlist is up
        spawn_link(fn ->
          try do
            StreamDoctor.Hls.await_playlist(hls_url, @hls_timeout)
            send(server, {:playlist_ready, id})
          rescue
            e -> send(server, {:viewer_failed, id, Exception.message(e)})
          end
        end)

        viewer = %{
          id: id,
          hls_url: hls_url,
          pid: nil,
          status: :waiting_for_playlist,
          error: nil,
          metrics: Metric.init_all(metric_specs)
        }

        viewer = notify_metrics(viewer, {:session_started, now_ms()})
        state = %{state | viewers: Map.put(state.viewers, id, viewer), next_id: state.next_id + 1}
        {:reply, {:ok, viewer_summary(viewer)}, state}
    end
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
      viewers: state.viewers |> Map.values() |> Enum.map(&viewer_summary/1),
      players: state.players |> Map.values() |> Enum.map(&player_summary/1)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:player_frame, id, decode_result, t}, _from, state) do
    player =
      Map.get(state.players, id, %{id: id, metrics: Metric.init_all(@player_metric_specs)})

    {player, response} =
      case decode_result do
        {:error, reason} ->
          {notify_metrics(player, {:undecoded, :video, reason, t}),
           %{decoded: false, reason: reason}}

        {:ok, n} ->
          player = notify_metrics(player, {:video_frame_received, n, nil, t})
          # matched if the metric's newest sample is the frame just recorded
          latency_ms =
            case Metric.report_all(player.metrics) do
              %{latency: %{latest_samples: [%{frame: ^n, latency_ms: latency} | _rest]}} -> latency
              _report -> nil
            end

          {player, %{decoded: true, frame: n, latency_ms: latency_ms}}
      end

    {:reply, response, put_in(state.players[id], player)}
  end

  @impl true
  def handle_call({:player, id}, _from, state) do
    case state.players[id] do
      nil -> {:reply, {:error, :not_found}, state}
      player -> {:reply, {:ok, player_summary(player)}, state}
    end
  end

  @impl true
  def handle_cast({:frame_sent, n, t}, state) do
    event = {:video_frame_sent, n, t}

    state = %{
      state
      | viewers: Map.new(state.viewers, fn {id, v} -> {id, notify_metrics(v, event)} end),
        players: Map.new(state.players, fn {id, p} -> {id, notify_metrics(p, event)} end)
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast({:viewer_event, id, event}, state) do
    case state.viewers[id] do
      nil -> {:noreply, state}
      viewer -> {:noreply, put_in(state.viewers[id], notify_metrics(viewer, event))}
    end
  end

  @impl true
  def handle_info({:playlist_ready, id}, state) do
    case state.viewers[id] do
      %{status: :waiting_for_playlist} = viewer ->
        server = self()

        pid =
          StreamDoctor.ReceiverPipeline.start_link(viewer.hls_url,
            # join at the newest segment and run unpaced so the rolling
            # minimum is the pure server latency
            live_edge?: true,
            realtime?: false,
            on_frame: fn
              {:ok, n, pts_ms} ->
                GenServer.cast(server, {:viewer_event, id, {:video_frame_received, n, pts_ms, now_ms()}})

              {:error, reason} ->
                GenServer.cast(server, {:viewer_event, id, {:undecoded, :video, reason, now_ms()}})
            end,
            on_audio_symbol: fn
              {:ok, m, pts_ms} ->
                GenServer.cast(server, {:viewer_event, id, {:audio_symbol_received, m, pts_ms, now_ms()}})

              {:error, reason} ->
                GenServer.cast(server, {:viewer_event, id, {:undecoded, :audio, reason, now_ms()}})
            end
          )

        Process.monitor(pid)
        viewer = notify_metrics(viewer, {:playlist_ready, now_ms()})
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

    state =
      cond do
        state.streamer != nil and state.streamer.pid == pid ->
          %{state | streamer: mark_down(state.streamer, error)}

        true ->
          case Enum.find(state.viewers, fn {_id, viewer} -> viewer.pid == pid end) do
            {id, viewer} -> put_in(state.viewers[id], mark_down(viewer, error))
            nil -> state
          end
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # pipelines are linked and monitored; bookkeeping happens on :DOWN
    {:noreply, state}
  end

  ## Helpers

  defp notify_metrics(entity, event) do
    %{entity | metrics: Metric.handle_event_all(entity.metrics, event)}
  end

  # an explicitly stopped pipeline stays :stopped; anything else that goes
  # down (finished input, crash) becomes :ended
  defp mark_down(%{status: :stopped} = entity, _error), do: entity
  defp mark_down(entity, error), do: %{entity | status: :ended, error: error}

  defp terminate_pipeline(%{pid: pid, status: status} = entity)
       when pid != nil and status in [:streaming, :receiving] do
    Membrane.Pipeline.terminate(pid)
    %{entity | status: :stopped}
  end

  defp terminate_pipeline(entity), do: %{entity | status: :stopped}

  defp streamer_summary(streamer) do
    Map.take(streamer, [:input, :rtmp_url, :status, :error])
  end

  defp viewer_summary(viewer) do
    %{
      id: viewer.id,
      hls_url: viewer.hls_url,
      status: viewer.status,
      error: viewer.error,
      metrics: Metric.report_all(viewer.metrics)
    }
  end

  defp player_summary(player) do
    %{id: player.id, metrics: Metric.report_all(player.metrics)}
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
