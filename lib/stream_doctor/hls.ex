defmodule StreamDoctor.Hls do
  @moduledoc """
  HLS playlist helpers: waits for a live playlist to become available before
  a receiver is started (`Membrane.HTTPAdaptiveStream.Source` has no retry
  option and crashes when the playlist is not there yet).
  """

  alias ExM3U8.{MediaPlaylist, MultivariantPlaylist}
  alias ExM3U8.Tags.{Segment, Stream}

  @doc """
  Blocks until the HLS playlist at `url` is available and contains at least
  one segment (or is a multivariant playlist), polling once a second.

  Prints progress and a summary of the playlist. Raises on timeout and when
  the playlist turns out to be a finished VoD recording.
  """
  @spec await_playlist(String.t(), non_neg_integer()) :: :ok
  def await_playlist(url, timeout) do
    IO.puts("waiting for HLS playlist at #{url}...")
    playlist = poll_hls(url, now_ms() + timeout)
    IO.puts("HLS playlist ready, starting receiver")
    describe_playlist(url, playlist)
  end

  defp poll_hls(url, deadline) do
    # ready when it has segments, or is a multivariant playlist pointing at
    # media playlists; a playlist without either would make the receiver
    # terminate at once. A playlist that doesn't parse yet (e.g. still being
    # written, missing #EXT-X-TARGETDURATION) counts as not ready.
    case fetch_playlist(url) do
      {:ok, %MultivariantPlaylist{} = playlist} -> playlist
      {:ok, %MediaPlaylist{} = playlist} when playlist.timeline != [] -> playlist
      {:ok, %MediaPlaylist{}} -> retry_hls(url, deadline, "playlist has no segments yet")
      {:error, reason} -> retry_hls(url, deadline, reason)
    end
  end

  defp retry_hls(url, deadline, reason) do
    if now_ms() > deadline do
      raise "HLS playlist not available at #{url} within timeout (last error: #{reason})"
    else
      Process.sleep(1_000)
      poll_hls(url, deadline)
    end
  end

  @spec fetch_playlist(String.t()) ::
          {:ok, MultivariantPlaylist.t() | MediaPlaylist.t()} | {:error, String.t()}
  defp fetch_playlist(url) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        parse_playlist(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  # `ExM3U8.deserialize_playlist/2` can't be used here: it tries the
  # multivariant parser first, which skips unknown lines and so happily turns
  # a media playlist into a multivariant one with no items.
  defp parse_playlist(body) do
    with {:ok, %MultivariantPlaylist{items: items}} when items != [] <-
           ExM3U8.deserialize_multivariant_playlist(body),
         true <- Enum.any?(items, &match?(%Stream{}, &1)) do
      {:ok, %MultivariantPlaylist{items: items}}
    else
      _other ->
        case ExM3U8.deserialize_media_playlist(body) do
          {:ok, playlist} -> {:ok, playlist}
          {:error, reason} -> {:error, "invalid playlist: #{inspect(reason)}"}
        end
    end
  end

  # Prints the media playlist's target duration and the resulting expected
  # baseline latency, so the measured numbers can be sanity-checked: the HLS
  # reader (like regular HLS players) joins ~2 target durations behind the
  # live edge, and the newest listed segment is on average half a target
  # duration old.
  defp describe_playlist(url, %MultivariantPlaylist{} = playlist) do
    with media_url when media_url != nil <- first_variant_url(url, playlist),
         {:ok, %MediaPlaylist{} = media} <- fetch_playlist(media_url) do
      describe_playlist(url, media)
    else
      _other -> :ok
    end
  end

  defp describe_playlist(url, %MediaPlaylist{info: %MediaPlaylist.Info{end_list?: true}}) do
    raise "the playlist at #{url} is a finished VoD recording (#EXT-X-ENDLIST), " <>
            "not a live stream - latency cannot be measured against it; " <>
            "use the channel's live playback URL while the stream is running"
  end

  defp describe_playlist(_url, %MediaPlaylist{info: info, timeline: timeline}) do
    target = info.target_duration
    segments = Enum.count(timeline, &match?(%Segment{}, &1))

    IO.puts(
      "playlist: #{segments} segments listed, target duration #{target} s - " <>
        "the reader joins at the newest listed segment, so the measured latency is " <>
        "the server's ingest-to-playlist delay plus that segment's age (0-#{target} s); " <>
        "a regular player joining ~#{2 * target} s behind the live edge would add that much on top"
    )
  end

  defp first_variant_url(base_url, %MultivariantPlaylist{items: items}) do
    Enum.find_value(items, fn
      %Stream{uri: uri} when is_binary(uri) -> base_url |> URI.merge(uri) |> URI.to_string()
      _other -> nil
    end)
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
