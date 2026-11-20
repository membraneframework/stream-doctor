defmodule StreamDoctor.HLS.Watcher do
  @moduledoc false

  use GenServer

  alias StreamDoctor.Metric

  @timeout 120_000
  @poll_interval 200
  @probe_percent 1
  @back_off_percent 5
  @recent_segments 3
  @min_gap_ms 200

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
      notify: opts.notify,
      gap_ms: nil,
      due: nil,
      missed_at: nil
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
    asked_at = Metric.now_ms()

    with {:segments, playlist} <- classify(state.url),
         newest when newest >= state.due <- newest(playlist) do
      notify(state, {:segment_available, newest, Metric.now_ms()})
      {:noreply, aim_at_next(state, playlist, asked_at)}
    else
      _due_segment_not_listed ->
        reload_at(asked_at + state.gap_ms)
        {:noreply, %{state | missed_at: asked_at}}
    end
  end

  defp poll(state) do
    at = Metric.now_ms()

    case classify(state.url) do
      {:segments, playlist} ->
        notify(state, {:first_frame_arrived, at})
        {:noreply, aim_at_next(state, playlist, at)}

      {:variant, url} when url != state.url ->
        {:noreply, %{state | url: url}, {:continue, :poll}}

      {:error, reason} ->
        retry(state, reason)

      _no_segments ->
        retry(state, "playlist has no segments yet")
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

  defp aim_at_next(state, playlist, asked_at) do
    segment_ms = shortest_recent_segment_ms(playlist)
    gap_ms = max(div(segment_ms, 2), @min_gap_ms)

    {appeared_at, percent} =
      case state.missed_at do
        nil -> {asked_at, -@probe_percent}
        missed_at -> {missed_at, @back_off_percent}
      end

    reload_at(max(appeared_at + segment_ms + div(segment_ms * percent, 100), asked_at + gap_ms))
    %{state | gap_ms: gap_ms, due: newest(playlist) + 1, missed_at: nil}
  end

  defp notify(%{notify: {pid, tag}}, event) do
    send(pid, {:hls, tag, event})
  end

  defp reload_at(at) do
    Process.send_after(self(), :reload, max(at - Metric.now_ms(), 0))
  end

  defp shortest_recent_segment_ms(playlist) do
    playlist
    |> segments()
    |> Enum.take(-@recent_segments)
    |> Enum.map(&round(&1.duration * 1_000))
    |> Enum.min()
  end

  defp newest(playlist) do
    playlist.info.media_sequence + length(segments(playlist)) - 1
  end

  defp segments(playlist) do
    Enum.filter(playlist.timeline, &match?(%ExM3U8.Tags.Segment{}, &1))
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
