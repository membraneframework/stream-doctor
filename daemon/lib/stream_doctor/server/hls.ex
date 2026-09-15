defmodule StreamDoctor.Server.HLS do
  @moduledoc false

  alias ExM3U8.{MediaPlaylist, MultivariantPlaylist}
  alias ExM3U8.Tags.{Segment, Stream}

  @doc "Polls `url` until it has segments (or variants). Raises on timeout / VoD."
  @spec await_playlist(String.t(), non_neg_integer()) :: :ok
  def await_playlist(url, timeout) do
    IO.puts("waiting for HLS playlist at #{url}...")
    playlist = poll_hls(url, now_ms() + timeout)
    IO.puts("HLS playlist ready, starting receiver")
    describe_playlist(url, playlist)
  end

  defp poll_hls(url, deadline) do
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

  # not deserialize_playlist/2: it happily parses a media playlist as an empty multivariant one
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
            "not a live stream, so latency cannot be measured against it. " <>
            "Use the channel's live playback URL while the stream is running"
  end

  defp describe_playlist(_url, %MediaPlaylist{info: info, timeline: timeline}) do
    target = info.target_duration
    segments = Enum.count(timeline, &match?(%Segment{}, &1))

    IO.puts(
      "playlist: #{segments} segments listed, target duration #{target} s. " <>
        "The reader joins at the newest listed segment, so the measured latency is " <>
        "the server's ingest-to-playlist delay plus that segment's age (0-#{target} s). " <>
        "A regular player joining ~#{2 * target} s behind the live edge would add that much on top"
    )
  end

  defp first_variant_url(base_url, %MultivariantPlaylist{items: items}) do
    Enum.find_value(items, fn
      %Stream{uri: uri} when is_binary(uri) -> base_url |> URI.merge(uri) |> URI.to_string()
      _other -> nil
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
