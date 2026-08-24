defmodule StreamDoctor.LatencyServer do
  @moduledoc """
  Holds latency-measurement state for the HTTP API (`StreamDoctor.Api`): one
  streamer pipeline and any number of viewer pipelines, all running in this
  BEAM node, so a single monotonic clock is shared - no clock synchronization
  issues.

  The streamer reports every video frame it sends; every viewer reports every
  frame it decodes; a viewer's latency for frame N = receive time - send time.
  Frame numbers wrap at `StreamDoctor.Bar.max_frame()`, so the send-time map
  is bounded (a new send overwrites the old slot).

  Like `StreamDoctor.Latency`, viewers join at the live edge and run unpaced,
  so frames arrive in per-segment batches; the reported `latency_ms` is the
  latency of the **first frame of the latest segment** - see that module's
  docs.

  Besides HLS viewers there are **players**: external players (e.g. the IVS
  player on a web page) whose frames are screenshot by the client and posted
  to the API, where `StreamDoctor.FrameImage` decodes the frame number. Their
  latency is `screenshot arrival time - send time` (measured on this node's
  clock; includes the client's capture + upload overhead, typically tens of
  ms), so it is the true "what the player shows right now" latency.
  """

  use GenServer
  require Logger

  # a pause in frame arrival longer than this marks the start of a new
  # segment batch (an unpaced viewer decodes a whole segment back-to-back,
  # then waits ~a segment duration for the next one)
  @segment_gap_ms 500
  @max_samples 50
  @hls_timeout 120_000

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

  @spec start_viewer(String.t()) :: {:ok, map()}
  def start_viewer(hls_url), do: GenServer.call(__MODULE__, {:start_viewer, hls_url})

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
    {:ok, %{streamer: nil, sent_at: %{}, viewers: %{}, players: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start_streamer, input, rtmp_url}, _from, state) do
    if state.streamer != nil and state.streamer.status == :streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      server = self()

      pid =
        StreamDoctor.stream_with_overlay(input, rtmp_url,
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
  def handle_call({:start_viewer, hls_url}, _from, state) do
    id = "viewer-#{state.next_id}"
    server = self()

    # wait for the playlist off-band so the API call returns immediately;
    # the receiver pipeline is started once the playlist is up
    spawn_link(fn ->
      try do
        StreamDoctor.Latency.await_hls(hls_url, @hls_timeout)
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
      last_recv_t: nil,
      segments_seen: 0,
      segment_latencies: [],
      samples: [],
      frames_matched: 0,
      frames_unmatched: 0
    }

    state = %{state | viewers: Map.put(state.viewers, id, viewer), next_id: state.next_id + 1}
    {:reply, {:ok, viewer_summary(viewer, now_ms())}, state}
  end

  @impl true
  def handle_call({:stop_viewer, id}, _from, state) do
    case state.viewers[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      viewer ->
        viewer = terminate_pipeline(viewer)
        state = put_in(state.viewers[id], viewer)
        {:reply, {:ok, viewer_summary(viewer, now_ms())}, state}
    end
  end

  @impl true
  def handle_call({:viewer, id}, _from, state) do
    case state.viewers[id] do
      nil -> {:reply, {:error, :not_found}, state}
      viewer -> {:reply, {:ok, viewer_summary(viewer, now_ms())}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    now = now_ms()

    status = %{
      streamer: state.streamer && streamer_summary(state.streamer),
      viewers: state.viewers |> Map.values() |> Enum.map(&viewer_summary(&1, now)),
      players: state.players |> Map.values() |> Enum.map(&player_summary/1)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:player_frame, id, decode_result, t}, _from, state) do
    player =
      Map.get(state.players, id, %{
        id: id,
        latency_ms: nil,
        samples: [],
        frames_matched: 0,
        frames_unmatched: 0,
        frames_undecoded: 0
      })

    {player, response} =
      case decode_result do
        {:error, reason} ->
          {%{player | frames_undecoded: player.frames_undecoded + 1},
           %{decoded: false, reason: reason}}

        {:ok, n} ->
          case state.sent_at[n] do
            nil ->
              {%{player | frames_unmatched: player.frames_unmatched + 1},
               %{decoded: true, frame: n, latency_ms: nil}}

            sent_t ->
              latency = t - sent_t

              player = %{
                player
                | latency_ms: latency,
                  samples: Enum.take([{n, latency} | player.samples], @max_samples),
                  frames_matched: player.frames_matched + 1
              }

              {player, %{decoded: true, frame: n, latency_ms: latency}}
          end
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
    {:noreply, put_in(state.sent_at[n], t)}
  end

  @impl true
  def handle_cast({:frame_received, id, n, t}, state) do
    case {state.viewers[id], state.sent_at[n]} do
      {nil, _sent_t} ->
        {:noreply, state}

      {viewer, nil} ->
        {:noreply,
         put_in(state.viewers[id], %{viewer | frames_unmatched: viewer.frames_unmatched + 1})}

      {viewer, sent_t} ->
        latency = t - sent_t

        first_of_segment? =
          viewer.last_recv_t == nil or t - viewer.last_recv_t > @segment_gap_ms

        segment_latencies =
          if first_of_segment?,
            do: Enum.take([latency | viewer.segment_latencies], @max_samples),
            else: viewer.segment_latencies

        viewer = %{
          viewer
          | last_recv_t: t,
            segments_seen: viewer.segments_seen + if(first_of_segment?, do: 1, else: 0),
            segment_latencies: segment_latencies,
            samples: Enum.take([{n, latency} | viewer.samples], @max_samples),
            frames_matched: viewer.frames_matched + 1
        }

        {:noreply, put_in(state.viewers[id], viewer)}
    end
  end

  @impl true
  def handle_info({:playlist_ready, id}, state) do
    case state.viewers[id] do
      %{status: :waiting_for_playlist} = viewer ->
        server = self()

        pid =
          StreamDoctor.read_frame_numbers(viewer.hls_url,
            # same rationale as in StreamDoctor.Latency: join at the newest
            # segment and run unpaced so the rolling minimum is the pure
            # server latency
            live_edge?: true,
            realtime?: false,
            on_frame: fn
              {:ok, n} -> GenServer.cast(server, {:frame_received, id, n, now_ms()})
              {:error, _reason} -> :ok
            end,
            on_audio_symbol: fn _result -> :ok end
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

  defp viewer_summary(viewer, _now) do
    %{
      id: viewer.id,
      hls_url: viewer.hls_url,
      status: viewer.status,
      error: viewer.error,
      frames_matched: viewer.frames_matched,
      frames_unmatched: viewer.frames_unmatched,
      # latency of the first frame of the latest segment
      latency_ms: List.first(viewer.segment_latencies),
      segments_seen: viewer.segments_seen,
      segment_latencies: viewer.segment_latencies,
      latest_samples:
        viewer.samples
        |> Enum.take(10)
        |> Enum.map(fn {n, latency} -> %{frame: n, latency_ms: latency} end)
    }
  end

  defp player_summary(player) do
    %{
      id: player.id,
      # latency of the most recent successfully decoded + matched screenshot
      latency_ms: player.latency_ms,
      frames_matched: player.frames_matched,
      frames_unmatched: player.frames_unmatched,
      frames_undecoded: player.frames_undecoded,
      latest_samples:
        player.samples
        |> Enum.take(10)
        |> Enum.map(fn {n, latency} -> %{frame: n, latency_ms: latency} end)
    }
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
