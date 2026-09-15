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
    linux_arm: [os: :linux, cpu: :aarch64],
    linux_x86: [os: :linux, cpu: :x86_64]
  ]

  defp releases do
    [
      stream_doctor: [
        steps: [:assemble, &StreamDoctor.Rel.Symlinks.run/1, &musl_stub/1, &Burrito.wrap/1],
        burrito: [
          targets: burrito_targets(),
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

  # We copy the local ERTS if we cannot use Burrito's precompiled
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

defmodule StreamDoctor.Rel.Symlinks do
  @manifest Path.expand("rel/burrito_plugin/symlinks.zon", __DIR__)

  @typep manifest_t :: [{link :: Path.t(), target :: Path.t()}]

  @spec run(Mix.Release.t()) :: Mix.Release.t()
  def run(%Mix.Release{} = release) do
    drop_headers(release)

    entries =
      Enum.flat_map(release.applications, fn {app, props} -> app_links(app, props, release) end)

    Enum.each(entries, fn {link, _target} -> File.rm_rf!(Path.join(release.path, link)) end)

    if entries == [] do
      Mix.raise(
        "#{inspect(__MODULE__)}: no symlinks found in any app's priv; refusing to write an empty manifest"
      )
    end

    File.mkdir_p!(Path.dirname(@manifest))
    File.write!(@manifest, to_zon(entries))

    Mix.shell().info(
      "symlinks: #{length(entries)} links; manifest: #{Path.relative_to_cwd(@manifest)}"
    )

    release
  end

  @spec drop_headers(Mix.Release.t()) :: :ok
  defp drop_headers(release) do
    release.path
    |> Path.join("lib/bundlex-*/priv/shared/precompiled/*/include")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)
  end

  @spec app_links(Application.app(), keyword(), Mix.Release.t()) :: manifest_t()
  defp app_links(app, props, release) do
    build_priv = build_priv(app)

    if File.dir?(build_priv) do
      build_priv
      |> find_symlinks()
      |> Enum.map(fn link ->
        raw = File.read_link!(link)
        rel_inside_priv = Path.relative_to(link, build_priv)

        case locate_target(Path.expand(raw, Path.dirname(link)), release) do
          {tapp, tprops, target_inside} ->
            link_rel = release_priv(app, props, rel_inside_priv)
            target_rel = release_priv(tapp, tprops, target_inside)
            {link_rel, Path.relative_to(target_rel, Path.dirname(link_rel), force: true)}

          nil ->
            Mix.raise("#{app}: priv/#{rel_inside_priv} -> #{raw} points outside every app's priv")
        end
      end)
    else
      []
    end
  end

  @spec find_symlinks(Path.t()) :: [Path.t()]
  defp find_symlinks(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      # don't follow directory symlinks
      case File.lstat!(path).type do
        :symlink -> [path]
        :directory -> find_symlinks(path)
        _ -> []
      end
    end)
  end

  @spec locate_target(Path.t(), Mix.Release.t()) :: {Application.app(), keyword(), Path.t()} | nil
  defp locate_target(abs, release) do
    Enum.find_value(release.applications, fn {app, props} ->
      case Path.relative_to(abs, build_priv(app)) do
        ^abs -> nil
        path_in_priv -> {app, props, path_in_priv}
      end
    end)
  end

  @spec build_priv(Application.app()) :: Path.t()
  defp build_priv(app), do: Path.join([Mix.Project.build_path(), "lib", to_string(app), "priv"])

  @spec release_priv(Application.app(), keyword(), Path.t()) :: Path.t()
  defp release_priv(app, props, inside),
    do: Path.join(["lib", "#{app}-#{props[:vsn]}", "priv", inside])

  @spec to_zon(manifest_t()) :: String.t()
  defp to_zon(entries),
    do: """
    .{
    #{Enum.map_join(entries, ",\n", fn {link, target} -> "    .{ #{zon_string(link)}, #{zon_string(target)} }" end)},
    }
    """

  # ZON strings use Zig escapes; paths are bytes, so only the two delimiters
  # need escaping (control characters would need \xNN and do not occur).
  @spec zon_string(String.t()) :: String.t()
  defp zon_string(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end
end
