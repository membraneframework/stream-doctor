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
      # 0.21 exposes the Source's live_edge_mode?; boombox pins 0.20, hence
      # the override (we use the Source directly in the receiver)
      {:membrane_http_adaptive_stream_plugin, "~> 0.21.3", override: true},
      # membrane_srt_plugin (via boombox) pins 1.3, which locks mpeg_ts to
      # ~> 2.0, while ex_hls 0.2 (live edge mode) needs mpeg_ts ~> 3.3;
      # 2.4 is compatible with both, and we don't use SRT input anyway
      {:membrane_mpeg_ts_plugin, "~> 2.4", override: true},
      {:membrane_aac_fdk_plugin, "~> 0.18"},
      # HTTP API for spawning streamer/viewers and reading latency
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
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
