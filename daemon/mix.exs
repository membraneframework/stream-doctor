defmodule StreamDoctor.MixProject do
  use Mix.Project

  def project do
    [
      app: :stream_doctor,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [flags: [:error_handling]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {StreamDoctor.Application, []}
    ]
  end

  defp deps do
    [
      {:membrane_file_plugin, "~> 0.17"},
      {:membrane_mp4_plugin, "~> 0.36"},
      {:membrane_http_adaptive_stream_plugin, "~> 0.21.3"},
      {:membrane_aac_fdk_plugin, "~> 0.19.0", override: true},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:membrane_realtimer_plugin, "~> 0.11.1"},
      {:membrane_rtmp_plugin, "~> 0.29.6", override: true},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32"},
      {:membrane_raw_video_format, "~> 0.4"},
      {:membrane_raw_audio_format, "~> 0.12"},
      {:membrane_transcoder_plugin, "~> 0.3"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20"},
      {:membrane_aac_format, "~> 0.8"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end
end
