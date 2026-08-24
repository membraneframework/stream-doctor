defmodule StreamDoctor.Latency do
  @moduledoc """
  Measures end-to-end latency: streams a file to RTMP with the frame-number
  overlay and reads it back from HLS, matching frame numbers on both sides.

  Latency of frame N = time it was decoded by the receiver minus time it left
  the sender (right before the RTMP sink, after real-time pacing). Both
  pipelines run in the same BEAM node, so a single monotonic clock is used -
  no clock synchronization issues.

  The receiver joins at the newest listed segment and decodes each segment as
  soon as it is downloaded, so per-frame latencies arrive in per-segment
  batches: the first frame of a segment shows the highest value (it waited a
  full segment duration to be packaged) and the last one the lowest. That
  lowest value is the **pure server latency** - how long a just-sent frame
  takes to become downloadable - and is reported separately as a rolling
  minimum.
  """

  require Logger

  @doc """
  Starts the sender and receiver pipelines and reports per-frame latency.

  Waits for the HLS playlist at `hls_url` to appear and contain at least one
  segment before starting the receiver (the RTMP server needs a moment to
  produce it).

  Options:
    * `:on_latency` - called with `%{frame: n, latency_ms: ms}` for every
      matched frame; defaults to printing `frame N: latency X ms`,
    * `:hls_timeout` - how long to wait for the HLS playlist, in ms
      (default `60_000`),
    * `:realtime?` - passed to the sender (default `true`).

  Returns `%{sender: pid, receiver: pid}`; both pipelines are linked to the
  calling process. Use `StreamDoctor.await/1` to block until they finish.
  """
  @spec measure(term(), String.t(), String.t(), keyword()) :: %{sender: pid(), receiver: pid()}
  def measure(input, rtmp_url, hls_url, opts \\ []) do
    on_latency = Keyword.get(opts, :on_latency, &report/1)

    collector =
      spawn_link(fn ->
        collect(%{sent_at: %{}, recent: [], last_summary_t: nil}, on_latency)
      end)

    sender =
      StreamDoctor.stream_with_overlay(input, rtmp_url,
        realtime?: Keyword.get(opts, :realtime?, true),
        on_video_frame_sent: fn n -> send(collector, {:sent, n, now_ms()}) end
      )

    await_hls(hls_url, Keyword.get(opts, :hls_timeout, 60_000))

    receiver =
      StreamDoctor.read_frame_numbers(hls_url,
        # join at the newest listed segment instead of the player-like
        # ~2 target durations behind the live edge - we measure the server's
        # latency, not a player's join back-off
        live_edge?: true,
        # no pacing: each frame is timestamped the moment its segment becomes
        # downloadable, so the per-segment minimum is the pure server latency;
        # pacing would lock the measurement to the join-point latency instead
        realtime?: false,
        on_frame: fn
          {:ok, n} -> send(collector, {:received, n, now_ms()})
          {:error, _reason} -> :ok
        end,
        on_audio_symbol: fn _result -> :ok end
      )

    %{sender: sender, receiver: receiver}
  end

  # window over which the "pure latency" rolling minimum is taken - long
  # enough to always contain the freshest frame of at least one segment batch
  @pure_window_ms 4_000
  @summary_interval_ms 1_000

  defp collect(state, on_latency) do
    receive do
      {:sent, n, t} ->
        collect(put_in(state.sent_at[n], t), on_latency)

      {:received, n, t} ->
        case Map.pop(state.sent_at, n) do
          {nil, _sent_at} ->
            Logger.warning("Received frame #{n} with no recorded send time")
            collect(state, on_latency)

          {sent_t, sent_at} ->
            latency = t - sent_t
            on_latency.(%{frame: n, latency_ms: latency})

            recent =
              [{t, latency} | state.recent]
              |> Enum.filter(fn {recv_t, _latency} -> recv_t > t - @pure_window_ms end)

            state = %{state | sent_at: sent_at, recent: recent}
            collect(maybe_report_pure(state, t), on_latency)
        end
    end
  end

  defp maybe_report_pure(%{last_summary_t: last} = state, t)
       when last != nil and t - last < @summary_interval_ms,
       do: state

  defp maybe_report_pure(state, t) do
    pure = state.recent |> Enum.map(fn {_recv_t, latency} -> latency end) |> Enum.min()
    IO.puts("pure latency (freshest frame of the last segments): #{pure} ms")
    %{state | last_summary_t: t}
  end

  defp report(%{frame: n, latency_ms: ms}), do: IO.puts("frame #{n}: latency #{ms} ms")

  defp await_hls(url, timeout) do
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
