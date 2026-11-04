defmodule StreamDoctor.Server.HLS do
  @moduledoc false

  # The HLS source crashes on a missing playlist, so the viewer waits here until one is served.

  alias StreamDoctor.Metric

  @poll_interval 200
  @sync_interval 200

  @doc """
  Polls `url` until a media playlist lists a segment, descending into a master's first variant,
  then keeps reloading that playlist and reporting the newest segment each reload brings.

  `report` is called with `{:first_frame_arrived, at_ms}`, then `{:media_available, media_end,
  at_ms}` per reload, and `{:timeline_broken, reason}` once the media offsets stop mapping onto
  what was published, which ends the watch. Raises if no segment shows up before the timeout.
  """
  @spec watch(String.t(), non_neg_integer(), (Metric.event() -> any())) :: :ok
  def watch(url, timeout, report) do
    {at, media_url, playlist} = poll(url, url, Metric.now_ms() + timeout)

    report.({:first_frame_arrived, at})

    cond do
      playlist.info.media_sequence > 0 -> end_watch(:missed_start, report)
      discontinuous?(playlist) -> end_watch(:discontinuity, report)
      true -> media_url |> start_watch(playlist, at, report) |> follow_playlist()
    end
  end

  defp poll(url, entry, deadline) do
    at = Metric.now_ms()

    case classify(url) do
      {:segments, playlist} -> {at, url, playlist}
      {:variant, ^url} -> retry(entry, deadline, "playlist has no segments yet")
      {:variant, variant} -> poll(variant, entry, deadline)
      :no_segments -> retry(entry, deadline, "playlist has no segments yet")
      {:error, reason} -> retry(entry, deadline, reason)
    end
  end

  defp retry(entry, deadline, reason) do
    if Metric.now_ms() > deadline do
      raise "HLS playlist not available at #{entry} within timeout (last error: #{reason})"
    end

    Process.sleep(@poll_interval)
    poll(entry, entry, deadline)
  end

  defp start_watch(url, playlist, at, report) do
    segments = segments(playlist)

    %{
      url: url,
      report: report,
      playlist: playlist,
      next: playlist.info.media_sequence + length(segments),
      media_end: Enum.reduce(segments, 0, &(&2 + duration(&1))),
      loaded_at: at,
      phase: :syncing,
      sync_until: at + 2 * target_duration_ms(playlist)
    }
  end

  defp follow_playlist(watch) do
    sleep_until(watch.loaded_at + reload_delay(watch))
    at = Metric.now_ms()

    case classify(watch.url) do
      {:segments, playlist} when playlist != watch.playlist ->
        advance_timeline(watch, playlist, at)

      _unchanged_or_unusable ->
        watch |> after_unchanged_reload(at) |> follow_playlist()
    end
  end

  defp after_unchanged_reload(%{phase: :syncing, sync_until: sync_until} = watch, at)
       when at < sync_until do
    %{watch | loaded_at: at}
  end

  defp after_unchanged_reload(watch, at) do
    %{watch | loaded_at: at, phase: :idle}
  end

  defp advance_timeline(watch, playlist, at) do
    cond do
      discontinuous?(playlist) ->
        end_watch(:discontinuity, watch.report)

      playlist.info.media_sequence > watch.next ->
        end_watch(:window_gap, watch.report)

      true ->
        watch |> report_new_media(playlist, at) |> follow_playlist()
    end
  end

  defp report_new_media(watch, playlist, at) do
    published = playlist |> segments() |> Enum.drop(watch.next - playlist.info.media_sequence)
    media_end = Enum.reduce(published, watch.media_end, &(&2 + duration(&1)))

    if published != [], do: watch.report.({:media_available, media_end, at})

    %{
      watch
      | playlist: playlist,
        next: watch.next + length(published),
        media_end: media_end,
        loaded_at: at,
        phase: :changed
    }
  end

  defp end_watch(reason, report) do
    report.({:timeline_broken, reason})
    :ok
  end

  # RFC 8216 section 6.3.4, after a hunt: a reload landing mid-cycle biases every sample.
  defp reload_delay(%{phase: :syncing}) do
    @sync_interval
  end

  defp reload_delay(%{phase: :changed} = watch) do
    target_duration_ms(watch.playlist)
  end

  defp reload_delay(%{phase: :idle} = watch) do
    div(target_duration_ms(watch.playlist), 2)
  end

  defp target_duration_ms(playlist) do
    playlist.info.target_duration * 1_000
  end

  defp sleep_until(at) do
    case at - Metric.now_ms() do
      remaining when remaining > 0 -> Process.sleep(remaining)
      _elapsed -> :ok
    end
  end

  defp segments(playlist) do
    Enum.filter(playlist.timeline, &match?(%ExM3U8.Tags.Segment{}, &1))
  end

  defp duration(segment) do
    Membrane.Time.nanoseconds(round(segment.duration * 1_000_000_000))
  end

  defp discontinuous?(playlist) do
    Enum.any?(playlist.timeline, &match?(%ExM3U8.Tags.Discontinuity{}, &1))
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
    # ExM3U8 raises on CR, which RFC 8216 section 4 allows.
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
