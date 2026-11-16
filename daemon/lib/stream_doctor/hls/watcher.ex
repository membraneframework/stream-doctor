defmodule StreamDoctor.HLS.Watcher do
  @moduledoc false

  use GenServer

  alias StreamDoctor.Metric

  @timeout 120_000
  @poll_interval 200
  @sync_interval 200

  @doc """
  Polls `url` until a media playlist lists a segment, descending into a master's first variant,
  then keeps reloading that playlist, sending each event to `notify`'s pid as `{:hls, tag, event}`.

  A playlist that never appears ends the watch with `{:shutdown, why}`.
  """
  @spec start_link(url: String.t(), timeout: non_neg_integer(), notify: {pid(), term()}) ::
          GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts))
  end

  @impl true
  def init(opts) do
    state = %{
      url: opts.url,
      entry: opts.url,
      deadline: Metric.now_ms() + Map.get(opts, :timeout, @timeout),
      notify: opts.notify
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    poll(state)
  end

  @impl true
  def handle_info(:poll, state) do
    poll(state)
  end

  @impl true
  def handle_info(:reload, state) do
    at = Metric.now_ms()

    case classify(state.url) do
      {:segments, playlist} when playlist != state.playlist ->
        advance_timeline(state, playlist, at)

      _unchanged_or_unusable ->
        {:noreply, state |> after_unchanged_reload(at) |> schedule_reload()}
    end
  end

  defp poll(state) do
    at = Metric.now_ms()

    case classify(state.url) do
      {:segments, playlist} -> start_watch(state, playlist, at)
      {:variant, url} when url == state.url -> retry(state, "playlist has no segments yet")
      {:variant, url} -> {:noreply, %{state | url: url}, {:continue, :poll}}
      :no_segments -> retry(state, "playlist has no segments yet")
      {:error, reason} -> retry(state, reason)
    end
  end

  defp retry(state, reason) do
    if Metric.now_ms() > state.deadline do
      {:stop,
       {:shutdown,
        "HLS playlist not available at #{state.entry} within timeout (last error: #{reason})"},
       state}
    else
      Process.send_after(self(), :poll, @poll_interval)
      {:noreply, %{state | url: state.entry}}
    end
  end

  defp start_watch(state, playlist, at) do
    notify(state, {:first_frame_arrived, at})

    state
    |> Map.merge(%{
      playlist: playlist,
      newest: newest(playlist),
      loaded_at: at,
      phase: :syncing,
      sync_until: at + 2 * target_duration_ms(playlist)
    })
    |> schedule_reload()
    |> then(&{:noreply, &1})
  end

  defp advance_timeline(state, playlist, at) do
    newest = newest(playlist)

    if newest > state.newest, do: notify(state, {:segment_available, newest, at})

    state = %{
      state
      | playlist: playlist,
        newest: max(newest, state.newest),
        loaded_at: at,
        phase: :changed
    }

    {:noreply, schedule_reload(state)}
  end

  defp after_unchanged_reload(%{phase: :syncing, sync_until: sync_until} = state, at)
       when at < sync_until do
    %{state | loaded_at: at}
  end

  defp after_unchanged_reload(state, at) do
    %{state | loaded_at: at, phase: :idle}
  end

  defp notify(%{notify: {pid, tag}}, event) do
    send(pid, {:hls, tag, event})
  end

  defp schedule_reload(state) do
    Process.send_after(
      self(),
      :reload,
      max(state.loaded_at + reload_delay(state) - Metric.now_ms(), 0)
    )

    state
  end

  defp reload_delay(%{phase: :syncing}) do
    @sync_interval
  end

  defp reload_delay(%{phase: :changed} = state) do
    target_duration_ms(state.playlist)
  end

  defp reload_delay(%{phase: :idle} = state) do
    div(target_duration_ms(state.playlist), 2)
  end

  defp target_duration_ms(playlist) do
    playlist.info.target_duration * 1_000
  end

  defp newest(playlist) do
    playlist.info.media_sequence +
      Enum.count(playlist.timeline, &match?(%ExM3U8.Tags.Segment{}, &1)) - 1
  end

  defp classify(url) do
    with {:ok, body} <- fetch(url) do
      cond do
        body =~ "#EXTINF" -> media(body)
        body =~ "#EXT-X-STREAM-INF" -> variant(body, url)
        true -> :no_segments
      end
    end
  end

  defp media(body) do
    case ExM3U8.deserialize_media_playlist(String.replace(body, "\r\n", "\n"), []) do
      {:ok, playlist} -> {:segments, playlist}
      {:error, reason} -> {:error, "media playlist: #{inspect(reason)}"}
    end
  end

  defp variant(body, base) do
    with {:ok, %{items: items}} <- ExM3U8.deserialize_multivariant_playlist(body, []),
         %ExM3U8.Tags.Stream{uri: uri} <- Enum.find(items, &match?(%ExM3U8.Tags.Stream{}, &1)) do
      {:variant, base |> URI.merge(uri) |> URI.to_string()}
    else
      _unusable -> :no_segments
    end
  end

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end
end
