defmodule Mix.Tasks.StreamDoctor.Latency do
  @shortdoc "Measures end-to-end latency from RTMP send to HLS receive"

  @moduledoc """
  Usage:

      mix stream_doctor.latency INPUT_FILE RTMP_URL HLS_PLAYLIST_URL

  Example:

      mix stream_doctor.latency test.mp4 rtmp://127.0.0.1:1935/live/test \\
        http://127.0.0.1:8123/index.m3u8

  Streams INPUT_FILE with the frame-number overlay to RTMP_URL, reads the
  stream back from HLS_PLAYLIST_URL and prints, for every video frame, the
  time between sending it and receiving it back.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case args do
      [input, rtmp_url, hls_url] ->
        Mix.Task.run("app.start")
        # silence Membrane's per-buffer debug logs so latency lines are readable
        Logger.configure(level: :info)

        %{sender: sender, receiver: receiver} =
          StreamDoctor.Latency.measure(input, rtmp_url, hls_url)

        StreamDoctor.await(sender)
        StreamDoctor.await(receiver)

      _other ->
        Mix.raise("Usage: mix stream_doctor.latency INPUT_FILE RTMP_URL HLS_PLAYLIST_URL")
    end
  end
end
