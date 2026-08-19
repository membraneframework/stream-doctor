defmodule StreamDoctor.MixProject do
  use Mix.Project

  def project do
    [
      app: :stream_doctor,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {StreamDoctor.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:boombox, "~> 0.2.13"},
      {:membrane_realtimer_plugin, "~> 0.11.1"},
      {:membrane_rtmp_plugin, "~> 0.29.5"},
      {:membrane_h264_plugin, "~> 0.9.3"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32"},
      {:membrane_raw_video_format, "~> 0.4"},
      {:membrane_raw_audio_format, "~> 0.12"},
      {:membrane_transcoder_plugin, "~> 0.3"},
      {:membrane_aac_format, "~> 0.8"}
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
