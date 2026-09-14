defmodule StreamDoctor.Rel.Symlinks do
  @moduledoc false

  @manifest Path.expand("burrito_plugin/symlinks.zon", __DIR__)

  def run(%Mix.Release{} = release) do
    lib_dir = Path.join(release.path, "lib")
    before = dir_size(lib_dir)

    drop_headers(release)

    restored =
      release.applications
      |> Enum.flat_map(fn {app, props} -> app_links(app, props, release) end)
      |> Enum.sort()
      |> Enum.map(fn {link, target} ->
        replace_with_link(release, link, target)
        {link, target}
      end)

    deduped = dedupe_bundles(release)
    entries = Enum.sort(restored ++ deduped)

    if entries == [] do
      Mix.raise("#{inspect(__MODULE__)}: no symlinks found in any app's priv; refusing to write an empty manifest")
    end

    File.mkdir_p!(Path.dirname(@manifest))
    File.write!(@manifest, to_zon(entries))

    Mix.shell().info(
      "symlinks: restored #{length(restored)}, deduped #{length(deduped)}; " <>
        "lib/: #{mb(before)} -> #{mb(dir_size(lib_dir))}; manifest: #{Path.relative_to_cwd(@manifest)}"
    )

    release
  end

  # ---- manifest -----------------------------------------------------------------

  # `.{ .{ "link", "target" }, ... }`; the plugin imports it as `[]const Link`.
  defp to_zon(entries) do
    body =
      Enum.map_join(entries, "", fn {link, target} ->
        "    .{ #{zon_string(link)}, #{zon_string(target)} },\n"
      end)

    ".{\n" <> body <> "}\n"
  end

  # ZON strings use Zig escapes; paths are bytes, so only the two delimiters
  # need escaping (control characters would need \xNN and do not occur).
  defp zon_string(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  # ---- release-side edits -----------------------------------------------------

  defp replace_with_link(release, link, target) do
    abs = Path.join(release.path, link)

    case File.lstat(abs) do
      {:ok, _} -> File.rm_rf!(abs)
      _ -> Mix.shell().info("  (no dereferenced copy at #{link})")
    end

    File.mkdir_p!(Path.dirname(abs))
    File.ln_s!(target, abs)
  end

  defp drop_headers(release) do
    release.path
    |> Path.join("lib/bundlex-*/priv/shared/precompiled/*/include")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)
  end

  # Byte-identical regular files within one bundle lib dir -> keep the longest
  # name (the fully versioned one), link the others to it. Returns manifest
  # entries. Runs after link restoration, so on macOS this usually finds
  # nothing; on Linux it collapses the alias copies the bundle ships as files.
  defp dedupe_bundles(release) do
    release.path
    |> Path.join("lib/bundlex-*/priv/shared/precompiled/*/lib")
    |> Path.wildcard()
    |> Enum.flat_map(fn lib_dir ->
      lib_dir
      |> File.ls!()
      |> Enum.map(&Path.join(lib_dir, &1))
      |> Enum.filter(&(File.lstat!(&1).type == :regular))
      |> Enum.group_by(fn f -> {File.stat!(f).size, :crypto.hash(:sha, File.read!(f))} end)
      |> Map.values()
      |> Enum.filter(&(length(&1) > 1))
      |> Enum.flat_map(fn files ->
        [keep | drop] = Enum.sort_by(files, &String.length(Path.basename(&1)), :desc)

        Enum.map(drop, fn file ->
          File.rm!(file)
          File.ln_s!(Path.basename(keep), file)
          {Path.relative_to(file, release.path), Path.basename(keep)}
        end)
      end)
    end)
  end

  # ---- discovery ----------------------------------------------------------------

  # Walk the build-tree priv of `app`; return [{release_link_path, relative_target}].
  defp app_links(app, props, release) do
    build_priv = build_priv(app)

    if File.dir?(build_priv) do
      build_priv
      |> find_symlinks()
      |> Enum.flat_map(fn link ->
        raw = File.read_link!(link)
        rel_inside = Path.relative_to(link, build_priv)
        link_dir = Path.dirname(link)

        # bundlex links (../../../../bundlex/priv/...) are relative to the
        # _build layout, not to the deps/ realpath; try lexical first.
        candidates = [Path.expand(raw, link_dir), Path.expand(raw, realpath(link_dir))]

        case Enum.find_value(candidates, &locate(&1, release)) do
          {tapp, tvsn, target_inside} ->
            link_rel = release_priv(app, props[:vsn], rel_inside)
            target_rel = release_priv(tapp, tvsn, target_inside)
            [{link_rel, relative_path(Path.dirname(link_rel), target_rel)}]

          nil ->
            Mix.shell().info("  skipping #{app}: priv/#{rel_inside} -> #{raw} (points outside any app's priv)")
            []
        end
      end)
    else
      []
    end
  end

  # Symlinks under dir, recursively; does not descend into symlinked dirs.
  defp find_symlinks(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      case File.lstat!(path).type do
        :symlink -> [path]
        :directory -> find_symlinks(path)
        _ -> []
      end
    end)
  end

  # Absolute path -> {app, vsn, path_inside_priv}, matching against every app's
  # build-tree priv both as written and fully resolved.
  defp locate(abs, release) do
    Enum.find_value(release.applications, fn {app, props} ->
      priv = build_priv(app)

      if File.dir?(priv) do
        real_priv = realpath(priv)

        Enum.find_value([{priv, abs}, {real_priv, abs}, {real_priv, realpath_dirname(abs)}], fn {base, path} ->
          if path == base or String.starts_with?(path, base <> "/") do
            {app, props[:vsn], Path.relative_to(path, base)}
          end
        end)
      end
    end)
  end

  defp build_priv(app), do: Path.join([Mix.Project.build_path(), "lib", to_string(app), "priv"])

  defp release_priv(app, vsn, ""), do: Path.join(["lib", "#{app}-#{vsn}", "priv"])
  defp release_priv(app, vsn, inside), do: Path.join(["lib", "#{app}-#{vsn}", "priv", inside])

  # ---- path helpers ---------------------------------------------------------------

  defp realpath(path) do
    ["/" | parts] = path |> Path.expand() |> Path.split()
    do_realpath(parts, "/")
  end

  defp do_realpath([], acc), do: acc

  defp do_realpath([part | rest], acc) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, target} -> do_realpath(rest, realpath(Path.expand(target, acc)))
      {:error, _} -> do_realpath(rest, candidate)
    end
  end

  # Canonicalise the directory only; keep the final component as written so
  # alias chains (libx.dylib -> libx.1.dylib -> ...) survive.
  defp realpath_dirname(abs), do: Path.join(realpath(Path.dirname(abs)), Path.basename(abs))

  defp relative_path(from, to) do
    {f, t} = drop_common(Path.split(from), Path.split(to))
    Path.join(List.duplicate("..", length(f)) ++ t)
  end

  defp drop_common([h | f], [h | t]), do: drop_common(f, t)
  defp drop_common(f, t), do: {f, t}

  # Bytes of regular files under dir, without following symlinks.
  defp dir_size(dir) do
    dir
    |> File.ls!()
    |> Enum.map(fn name ->
      path = Path.join(dir, name)

      case File.lstat!(path) do
        %{type: :regular, size: size} -> size
        %{type: :directory} -> dir_size(path)
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp mb(bytes), do: "#{div(bytes, 1_000_000)} MB"
end
