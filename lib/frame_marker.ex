defmodule FrameMarker do
  @moduledoc """
  Overlays a machine-readable frame-number bar on a video and streams it via
  RTMP; reads the bar back from an HLS stream.

  Both functions start a supervised `Membrane.Pipeline` and return immediately,
  so they can be called from anywhere - a script, IEx, or e.g. a Phoenix
  controller handling an HTTP request. Use `await/1` to block until a pipeline
  terminates (e.g. in scripts).
  """

  @doc """
  Reads `input` (e.g. an MP4 file path or any other Boombox input), draws the
  frame-number bar on the video and streams it to `rtmp_url`.

  Options:
    * `:realtime?` - pace the stream to real time (default `true`).

  Returns the pipeline pid.
  """
  @spec stream_with_overlay(term(), String.t(), keyword()) :: pid()
  def stream_with_overlay(input, rtmp_url, opts \\ []) do
    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(
        FrameMarker.SenderPipeline,
        [input: input, rtmp_url: rtmp_url] ++ opts
      )

    pipeline
  end

  @doc """
  Reads the HLS playlist at `url`, decodes the video and restores frame numbers
  from the bar.

  Options:
    * `:on_frame` - a function called with `{:ok, frame_number}` or
      `{:error, reason}` for every video frame; defaults to logging,
    * `:on_audio_symbol` - a function called with `{:ok, symbol_number}` or
      `{:error, reason}` for every 30 ms audio symbol; defaults to logging.

  Returns the pipeline pid.
  """
  @spec read_frame_numbers(String.t(), keyword()) :: pid()
  def read_frame_numbers(url, opts \\ []) do
    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(FrameMarker.ReceiverPipeline, [url: url] ++ opts)

    pipeline
  end

  @doc """
  Blocks until the given pipeline terminates.
  """
  @spec await(pid()) :: :ok
  def await(pipeline) do
    ref = Process.monitor(pipeline)

    receive do
      {:DOWN, ^ref, :process, ^pipeline, _reason} -> :ok
    end
  end
end
