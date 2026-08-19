defmodule Mix.Tasks.FrameMarker.Read do
  @shortdoc "Reads frame numbers from an HLS stream"

  @moduledoc """
  Usage:

      mix frame_marker.read HLS_PLAYLIST_URL

  Example:

      mix frame_marker.read http://localhost:8888/hls/index.m3u8

  Prints the frame number decoded from each video frame.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case args do
      [url] ->
        Mix.Task.run("app.start")

        url
        |> FrameMarker.read_frame_numbers(
          on_frame: fn
            {:ok, frame_number} -> IO.puts("frame #{frame_number}")
            {:error, reason} -> IO.puts("frame decode error: #{inspect(reason)}")
          end,
          on_audio_symbol: fn
            {:ok, symbol_number} -> IO.puts("audio #{symbol_number}")
            {:error, reason} -> IO.puts("audio decode error: #{inspect(reason)}")
          end
        )
        |> FrameMarker.await()

      _other ->
        Mix.raise("Usage: mix frame_marker.read HLS_PLAYLIST_URL")
    end
  end
end
