defmodule StreamDoctor.SenderPipeline.Ingest.Synthetic do
  @moduledoc """
  Sources that generate a video and a mono audio stream, with `metadata.duration` on every
  video buffer.

  Without a `duration` they never end; they run until the pipeline is terminated.
  """

  import Membrane.ChildrenSpec

  alias Membrane.RawAudio
  alias StreamDoctor.OptionsParser.Publisher.Synthetic, as: Config
  alias StreamDoctor.SenderPipeline.Ingest.Synthetic.VideoSource

  @frames_per_buffer 1024

  @spec tracks(Config.t()) :: %{
          video: Membrane.ChildrenSpec.t(),
          audio: Membrane.ChildrenSpec.t()
        }
  def tracks(config) do
    %{video: video(config), audio: audio(config)}
  end

  defp video(config) do
    child(:video_source, %VideoSource{
      width: config.video.width,
      height: config.video.height,
      framerate: List.to_tuple(config.video.fps),
      duration: duration(config.duration)
    })
  end

  # Silence is enough: the marker encoder replaces the payload with its tones.
  defp audio(config) do
    child(:audio_source, %Membrane.SilenceGenerator{
      stream_format: %RawAudio{
        sample_format: :s16le,
        channels: 1,
        sample_rate: config.audio.sample_rate
      },
      duration: duration(config.duration),
      frames_per_buffer: @frames_per_buffer
    })
  end

  defp duration(nil), do: :infinity
  defp duration(seconds), do: Membrane.Time.seconds(seconds)
end
