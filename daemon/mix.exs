Code.require_file("rel/slim.exs")

defmodule StreamDoctor.MixProject do
  use Mix.Project

  def project do
    [
      app: :stream_doctor,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      dialyzer: [flags: [:error_handling]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {StreamDoctor.Application, []}
    ]
  end

  @burrito_targets [
    macos_arm: [os: :darwin, cpu: :aarch64],
    macos_x86: [os: :darwin, cpu: :x86_64],
    linux_arm: [os: :linux, cpu: :aarch64],
    linux_x86: [os: :linux, cpu: :x86_64]
  ]

  defp releases do
    [
      stream_doctor: [
        steps: [:assemble, &StreamDoctor.Rel.Slim.run/1, &Burrito.wrap/1],
        burrito: [targets: burrito_targets()]
      ]
    ]
  end

  # the NIFs are compiled for the host, so a cross build can never run; without
  # BURRITO_TARGET build only the host's target instead of all of them
  defp burrito_targets do
    if System.get_env("BURRITO_TARGET") do
      @burrito_targets
    else
      {os, cpu} = host()
      Enum.filter(@burrito_targets, fn {_, t} -> t[:os] == os and t[:cpu] == cpu end)
    end
  end

  defp host do
    os =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
      end

    cpu =
      case to_string(:erlang.system_info(:system_architecture)) do
        "aarch64" <> _ -> :aarch64
        "arm64" <> _ -> :aarch64
        "x86_64" <> _ -> :x86_64
      end

    {os, cpu}
  end

  defp deps do
    [
      {:boombox, "~> 0.2.13"},
      # need live_edge_mode?, boombox pins 0.20
      {:membrane_http_adaptive_stream_plugin, "~> 0.21.3", override: true},
      # srt plugin vs ex_hls mpeg_ts conflict, 2.4 works for both
      {:membrane_mpeg_ts_plugin, "~> 2.4", override: true},
      {:membrane_aac_fdk_plugin, "~> 0.19.0", override: true},
      {:ex_m3u8, "~> 0.15"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:membrane_realtimer_plugin, "~> 0.11.1"},
      {:membrane_rtmp_plugin, "~> 0.29.6", override: true},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32"},
      {:membrane_raw_video_format, "~> 0.4"},
      {:membrane_raw_audio_format, "~> 0.12"},
      {:membrane_transcoder_plugin, "~> 0.3"},
      {:membrane_aac_format, "~> 0.8"},
      {:burrito, "~> 1.6", runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end
end
