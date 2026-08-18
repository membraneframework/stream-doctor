defmodule Mix.Tasks.FrameMarker.Send do
  @shortdoc "Streams a file with the frame-number overlay to an RTMP URL"

  @moduledoc """
  Usage:

      mix frame_marker.send INPUT_FILE RTMP_URL [--no-realtime]

  Example:

      mix frame_marker.send input.mp4 rtmp://localhost:1935/app/stream_key
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: [realtime: :boolean])

    case args do
      [input, rtmp_url] ->
        Mix.Task.run("app.start")

        input
        |> FrameMarker.stream_with_overlay(rtmp_url,
          realtime?: Keyword.get(opts, :realtime, true)
        )
        |> FrameMarker.await()

      _other ->
        Mix.raise("Usage: mix frame_marker.send INPUT_FILE RTMP_URL [--no-realtime]")
    end
  end
end
