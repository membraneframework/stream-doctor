defmodule StreamDoctor.Source.Synthetic do
  @moduledoc """
  Sources that generate a mono video and audio stream, with `metadata.duration` on every
  video buffer.

  Without a `duration` they never end; they run until the pipeline is terminated.
  """

  import Membrane.ChildrenSpec

  alias StreamDoctor.Input.Synthetic, as: Config
  alias StreamDoctor.Source.Synthetic.{AudioSource, VideoSource}

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
      framerate: config.video.fps,
      duration: duration(config.duration)
    })
  end

  defp audio(config) do
    child(:audio_source, %AudioSource{
      sample_rate: config.audio.sample_rate,
      duration: duration(config.duration)
    })
  end

  defp duration(nil), do: nil
  defp duration(seconds), do: Membrane.Time.seconds(seconds)
end
