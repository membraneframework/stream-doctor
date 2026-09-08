defmodule StreamDoctor.Server do
  @moduledoc """
  Holds measurement state for the HTTP API (`StreamDoctor.Api`): one streamer
  pipeline and any number of viewer pipelines, all running in this BEAM node,
  so a single monotonic clock is shared - no clock synchronization issues.

  All measurement math lives in `StreamDoctor.Metric` implementations, held
  by one `StreamDoctor.Metric.Collector` process per viewer/player session;
  the probes report their events straight to the session's collector (send
  events are broadcast to all collectors). This server only manages pipeline
  lifecycle, starts the collectors and pulls their reports for the summaries.

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
  alias StreamDoctor.Metric.Collector

  @hls_timeout 120_000

  @player_metric_specs [{Metric.Latency, [mode: :latest]}]
  # audio send history kept for seeding (AAC frames are ~21 ms: ~40 s)
  @recent_audio_sends 2000

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
    # for the streamer's frames_sent counter (backing "is it live yet?") and
    # the recent-sends history seeded into late-created collectors
    :ok = Collector.subscribe_send_events()
    {:ok, %{streamer: nil, viewers: %{}, players: %{}, next_id: 1, recent_sends: empty_sends()}}
  end

  @impl true
  def handle_call({:start_streamer, input, rtmp_url}, _from, state) do
    if state.streamer != nil and state.streamer.status == :streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      pid = StreamDoctor.SenderPipeline.start_link(input, rtmp_url, realtime?: true)

      Process.monitor(pid)

      streamer = %{
        pid: pid,
        input: input,
        rtmp_url: rtmp_url,
        status: :streaming,
        error: nil,
        frames_sent: 0
      }

      # a new stream restarts the frame numbering - drop the old history
      {:reply, {:ok, streamer_summary(streamer)},
       %{state | streamer: streamer, recent_sends: empty_sends()}}
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

        {:ok, collector} = Collector.start_link(metric_specs)
        Collector.event(collector, {:session_started, now_ms()})
        seed_sends(collector, state.recent_sends)

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
      Map.get_lazy(state.players, id, fn ->
        {:ok, collector} = Collector.start_link(@player_metric_specs)
        seed_sends(collector, state.recent_sends)
        %{id: id, collector: collector}
      end)

    response =
      case decode_result do
        {:error, reason} ->
          Collector.event(player.collector, {:undecoded, :video, reason, t})
          %{decoded: false, reason: reason}

        {:ok, n} ->
          report =
            Collector.event_and_report(player.collector, {:video_frame_received, n, nil, t})

          # matched if the metric's newest sample is the frame just recorded
          latency_ms =
            case report do
              %{latency: %{latest_samples: [%{frame: ^n, latency_ms: latency} | _rest]}} ->
                latency

              _report ->
                nil
            end

          %{decoded: true, frame: n, latency_ms: latency_ms}
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
  def handle_cast({:event, {:video_frame_sent, n, t}}, state) do
    streamer =
      state.streamer && %{state.streamer | frames_sent: state.streamer.frames_sent + 1}

    # bounded: frame numbers wrap, so a new send overwrites the old slot
    recent_sends = %{state.recent_sends | video: Map.put(state.recent_sends.video, n, t)}
    {:noreply, %{state | streamer: streamer, recent_sends: recent_sends}}
  end

  @impl true
  def handle_cast({:event, {:audio_sent, media_ms, t}}, state) do
    audio = Enum.take([{media_ms, t} | state.recent_sends.audio], @recent_audio_sends)
    {:noreply, %{state | recent_sends: %{state.recent_sends | audio: audio}}}
  end

  @impl true
  def handle_cast({:event, _event}, state), do: {:noreply, state}

  @impl true
  def handle_info({:playlist_ready, id}, state) do
    case state.viewers[id] do
      %{status: :waiting_for_playlist} = viewer ->
        pid =
          StreamDoctor.ReceiverPipeline.start_link(viewer.hls_url,
            # join at the newest segment and run unpaced so the rolling
            # minimum is the pure server latency
            live_edge?: true,
            realtime?: false,
            collector: viewer.collector
          )

        Process.monitor(pid)
        Collector.event(viewer.collector, {:playlist_ready, now_ms()})
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

  # Replays the send history into a freshly created collector: sessions start
  # after the streamer, and what they display/decode was sent up to their full
  # latency earlier - without the history those frames would never match a
  # send time.
  defp seed_sends(collector, recent_sends) do
    video = Enum.map(recent_sends.video, fn {n, t} -> {t, {:video_frame_sent, n, t}} end)
    audio = Enum.map(recent_sends.audio, fn {m, t} -> {t, {:audio_sent, m, t}} end)

    (video ++ audio)
    |> Enum.sort_by(fn {t, _event} -> t end)
    |> Enum.each(fn {_t, event} -> Collector.event(collector, event) end)
  end

  # video: frame number => send time (bounded by the counter wrap); audio:
  # most recent {media_ms, send time} first
  defp empty_sends(), do: %{video: %{}, audio: []}

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
    Map.take(streamer, [:input, :rtmp_url, :status, :error, :frames_sent])
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

  defp player_summary(player) do
    %{id: player.id, metrics: safe_report(player.collector)}
  end

  # a collector taken down by a crashing metric shouldn't take the summary
  # (and this server) with it
  defp safe_report(collector) do
    Collector.report(collector)
  catch
    :exit, _reason -> %{error: "metrics collector down"}
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
