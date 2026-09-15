Code.require_file("rel/symlinks.exs")

defmodule StreamDoctor.MixProject do
  use Mix.Project

  def project do
    [
      app: :stream_doctor,
      version: "0.0.4",
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
    linux_arm: [os: :linux, cpu: :aarch64],
    linux_x86: [os: :linux, cpu: :x86_64]
  ]

  defp releases do
    [
      stream_doctor: [
        steps: [:assemble, &StreamDoctor.Rel.Symlinks.run/1, &musl_stub/1, &Burrito.wrap/1],
        burrito: [
          targets: burrito_targets(),
          # recreates the symlinks rel/symlinks.exs recorded, on every launch
          plugin: "rel/burrito_plugin/symlinks.zig"
        ]
      ]
    ]
  end

  # Burrito 1.6.0 embeds src/musl-runtime.so into the Linux wrapper even with a
  # custom_erts, where its musl fetch step never writes the file (upstream PR
  # burrito-elixir/burrito#237). The path baked in is empty then, so the bytes
  # are never used; an empty file only lets the Zig build go through.
  defp musl_stub(release) do
    File.write!("deps/burrito/src/musl-runtime.so", "")
    release
  end

  # the NIFs are compiled for the host, so a cross build can never run; without
  # BURRITO_TARGET build only the host's target instead of all of them
  defp burrito_targets do
    {os, cpu} = host()
    host? = fn t -> t[:os] == os and t[:cpu] == cpu end

    targets =
      if System.get_env("BURRITO_TARGET"),
        do: @burrito_targets,
        else: Enum.filter(@burrito_targets, fn {_, t} -> host?.(t) end)

    for {name, t} <- targets do
      if host?.(t), do: {name, t ++ custom_erts()}, else: {name, t}
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

  # Burrito downloads a prebuilt ERTS matching the OTP that runs `mix release`
  # (../shell.nix pins one that Beam Machine serves). When none exists for the
  # host's OTP, or it is unusable (the Linux ones are musl builds that cannot
  # load glibc NIFs), run rel/pack_host_erts.sh; its tarball is used instead,
  # but only if it matches the running OTP. Host == target only.
  defp custom_erts do
    with [otp | _] <- Path.wildcard(Path.join([:code.root_dir(), "releases", "*", "OTP_VERSION"])),
         {:ok, version} <- File.read(otp),
         [path | _] <- Path.wildcard("_build/custom_erts/otp-#{String.trim(version)}-*.tar.gz") do
      [custom_erts: Path.expand(path)]
    else
      _ -> []
    end
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
      {:burrito, "~> 1.6", runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end
end
