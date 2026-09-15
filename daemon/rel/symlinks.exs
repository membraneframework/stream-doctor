defmodule StreamDoctor.Rel.Symlinks do
  @moduledoc """
  This release step:
  - prunes headers added by bundlex,
  - Removes duplicate libs made from `mix release` dereferencing symlinks,
  - Saves the links to a manifest file so the burrito plugin can recreate them
    when installing the app.
    

  bundlex downloads each precompiled package (ffmpeg, srt, ...) once into its own
  `priv/shared/precompiled/<package>` and gives every plugin a relative symlink
  at `priv/bundlex/nif/<package>`; the NIF's rpath points at that link. Inside a
  package, versioned library aliases (`libx.so`, `libx.so.1`) are symlinks too.

  This step, in pure Elixir:

    1. discovers every symlink inside each app's `priv` in the build tree and
       maps it to release paths (`lib/<app>-<vsn>/priv/...`), across apps;
  """

  @manifest Path.expand("burrito_plugin/symlinks.zon", __DIR__)

  @type manifest_t :: [{link :: Path.t(), target :: Path.t()}]

  # Version string as read from the `.app` file (a charlist).
  @typep vsn :: charlist()

  # A located path: owning app, its version, and the path inside that app's priv.
  @typep located :: {Application.app(), vsn(), Path.t()}

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

  # Walk the build-tree priv of `app`; return [{release_link_path, relative_target}].
  @spec app_links(Application.app(), keyword(), Mix.Release.t()) :: manifest_t()
  defp app_links(app, props, release) do
    build_priv = build_priv(app)

    if File.dir?(build_priv) do
      build_priv
      |> find_symlinks()
      |> Enum.flat_map(fn link ->
        raw = File.read_link!(link)
        rel_inside = Path.relative_to(link, build_priv)

        # bundlex writes its links relative to the _build layout
        # (../../../../bundlex/priv/...), so lexical expansion is enough.
        case locate(Path.expand(raw, Path.dirname(link)), release) do
          {tapp, tvsn, target_inside} ->
            link_rel = release_priv(app, props[:vsn], rel_inside)
            target_rel = release_priv(tapp, tvsn, target_inside)
            [{link_rel, Path.relative_to(target_rel, Path.dirname(link_rel), force: true)}]

          nil ->
            Mix.raise("#{app}: priv/#{rel_inside} -> #{raw} points outside every app's priv")
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

  # Absolute build-tree path -> {app, vsn, path_inside_priv}.
  @spec locate(Path.t(), Mix.Release.t()) :: located() | nil
  defp locate(abs, release) do
    Enum.find_value(release.applications, fn {app, props} ->
      priv = build_priv(app)

      if String.starts_with?(abs, priv <> "/") do
        {app, props[:vsn], Path.relative_to(abs, priv)}
      end
    end)
  end

  @spec build_priv(Application.app()) :: Path.t()
  defp build_priv(app), do: Path.join([Mix.Project.build_path(), "lib", to_string(app), "priv"])

  @spec release_priv(Application.app(), vsn(), Path.t()) :: Path.t()
  defp release_priv(app, vsn, inside), do: Path.join(["lib", "#{app}-#{vsn}", "priv", inside])

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
