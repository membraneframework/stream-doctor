defmodule StreamDoctor.Hls do
  @moduledoc """
  HLS playlist helpers: waits for a live playlist to become available before
  a receiver is started (`Membrane.HTTPAdaptiveStream.Source` has no retry
  option and crashes when the playlist is not there yet).
  """

  @doc """
  Blocks until the HLS playlist at `url` is available and contains at least
  one segment (or is a multivariant playlist), polling once a second.

  Prints progress and a summary of the playlist. Raises on timeout and when
  the playlist turns out to be a finished VoD recording.
  """
  @spec await_playlist(String.t(), non_neg_integer()) :: :ok
  def await_playlist(url, timeout) do
    IO.puts("waiting for HLS playlist at #{url}...")
    body = poll_hls(url, now_ms() + timeout)
    IO.puts("HLS playlist ready, starting receiver")
    describe_playlist(url, body)
  end

  defp poll_hls(url, deadline) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        # ready when it has segments, or is a multivariant playlist pointing
        # at media playlists; a playlist without either would make the
        # receiver terminate at once
        if String.contains?(body, "#EXTINF") or String.contains?(body, "#EXT-X-STREAM-INF") do
          body
        else
          retry_hls(url, deadline, "playlist has no segments yet")
        end

      {:ok, %Req.Response{status: status}} ->
        retry_hls(url, deadline, "HTTP #{status}")

      {:error, error} ->
        retry_hls(url, deadline, Exception.message(error))
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

  # Prints the media playlist's target duration and the resulting expected
  # baseline latency, so the measured numbers can be sanity-checked: the HLS
  # reader (like regular HLS players) joins ~2 target durations behind the
  # live edge, and the newest listed segment is on average half a target
  # duration old.
  defp describe_playlist(url, body) do
    body =
      if String.contains?(body, "#EXT-X-STREAM-INF") do
        with media_url when media_url != nil <- first_variant_url(url, body),
             {:ok, %Req.Response{status: 200, body: media_body}} <-
               Req.get(media_url, retry: false, receive_timeout: 5_000) do
          media_body
        else
          _other -> nil
        end
      else
        body
      end

    if body != nil and String.contains?(body, "#EXT-X-ENDLIST") do
      raise "the playlist at #{url} is a finished VoD recording (#EXT-X-ENDLIST), " <>
              "not a live stream - latency cannot be measured against it; " <>
              "use the channel's live playback URL while the stream is running"
    end

    with body when body != nil <- body,
         [_full, target] <- Regex.run(~r/#EXT-X-TARGETDURATION:(\d+)/, body) do
      target = String.to_integer(target)
      segments = body |> String.split("#EXTINF") |> length() |> Kernel.-(1)

      IO.puts(
        "playlist: #{segments} segments listed, target duration #{target} s - " <>
          "the reader joins at the newest listed segment, so the measured latency is " <>
          "the server's ingest-to-playlist delay plus that segment's age (0-#{target} s); " <>
          "a regular player joining ~#{2 * target} s behind the live edge would add that much on top"
      )
    else
      _other -> :ok
    end
  end

  defp first_variant_url(base_url, body) do
    body
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "#EXT-X-STREAM-INF")))
    |> Enum.find(&(String.trim(&1) != "" and not String.starts_with?(&1, "#")))
    |> case do
      nil -> nil
      uri -> base_url |> URI.merge(String.trim(uri)) |> URI.to_string()
    end
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
