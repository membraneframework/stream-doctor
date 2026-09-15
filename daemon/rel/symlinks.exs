defmodule StreamDoctor.Rel.Symlinks do
  @moduledoc """
  This release step:
  - prunes headers added by bundlex,
  - Removes duplicate libs made from `mix release` dereferencing symlinks,
  - Saves the links to a manifest file so the burrito plugin can recreate them
    when installing the app.
  """

  @manifest Path.expand("burrito_plugin/symlinks.zon", __DIR__)

  @typep manifest_t :: [{link :: Path.t(), target :: Path.t()}]

  # A located path: owning app, its props, and the path inside that app's priv.
  @typep located :: {Application.app(), keyword(), Path.t()}

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

        case locate(Path.expand(raw, Path.dirname(link)), release) do
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

  @spec locate(Path.t(), Mix.Release.t()) :: located() | nil
  defp locate(abs, release) do
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
  defp release_priv(app, props, inside), do: Path.join(["lib", "#{app}-#{props[:vsn]}", "priv", inside])

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
