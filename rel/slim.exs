defmodule StreamDoctor.Rel.Slim do
  @moduledoc false

  # `mix release` copies every priv dir with symlinks dereferenced, which
  # turns bundlex's precompiled bundles into a mess: each plugin gets its
  # own full copy of e.g. ffmpeg, and every dylib version alias becomes a
  # full file. Burrito can't ship symlinks at all, so instead of restoring
  # them we rewrite the Mach-O load commands to point at a single copy.
  # macOS only for now (Linux would need patchelf).

  def run(%Mix.Release{} = release) do
    if match?({:unix, :darwin}, :os.type()) do
      lib = Path.join(release.path, "lib")
      shared = Path.wildcard(Path.join(lib, "bundlex-*/priv/shared/precompiled")) |> List.first()

      if shared do
        before = dir_size(lib)
        drop_headers(shared)
        canonical = dedupe_dylibs(shared)
        rewrite_references(lib, canonical)
        share_bundles(lib, shared)
        Mix.shell().info("slimmed lib/: #{mb(before)} -> #{mb(dir_size(lib))}")
      end
    end

    release
  end

  defp drop_headers(shared) do
    shared |> Path.join("*/include") |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)
  end

  # identical dylibs within a bundle -> keep the longest name (the fully
  # versioned one, which is what the NIFs link against); returns
  # %{alias => canonical}
  defp dedupe_dylibs(shared) do
    shared
    |> Path.join("*/lib")
    |> Path.wildcard()
    |> Enum.flat_map(fn lib_dir ->
      lib_dir
      |> Path.join("*.dylib")
      |> Path.wildcard()
      |> Enum.group_by(fn f -> {File.stat!(f).size, :crypto.hash(:sha, File.read!(f))} end)
      |> Map.values()
      |> Enum.filter(&(length(&1) > 1))
      |> Enum.flat_map(fn files ->
        [keep | drop] = Enum.sort_by(files, &String.length(Path.basename(&1)), :desc)
        Enum.each(drop, &File.rm!/1)
        Enum.map(drop, &{Path.basename(&1), Path.basename(keep)})
      end)
    end)
    |> Map.new()
  end

  defp rewrite_references(lib, canonical) when map_size(canonical) > 0 do
    lib
    |> Path.join("**/*.{dylib,so}")
    |> Path.wildcard()
    |> Enum.each(fn file ->
      changes =
        file
        |> referenced_names()
        |> Enum.filter(&Map.has_key?(canonical, &1))
        |> Enum.flat_map(&["-change", "@rpath/#{&1}", "@rpath/#{canonical[&1]}"])

      if changes != [], do: patch(file, changes)
    end)
  end

  defp rewrite_references(_lib, _canonical), do: :ok

  # plugin/priv/bundlex/nif/<bundle> is a copy of shared/<bundle>/lib and the
  # NIF's rpath points at it; point the rpath at the shared one instead
  defp share_bundles(lib, shared) do
    bundlex_dir = shared |> Path.relative_to(lib) |> Path.split() |> hd()

    lib
    |> Path.join("*/priv/bundlex/nif/*")
    |> Path.wildcard()
    |> Enum.filter(&(File.dir?(&1) and File.dir?(Path.join([shared, Path.basename(&1), "lib"]))))
    |> Enum.each(fn copy ->
      bundle = Path.basename(copy)
      File.rm_rf!(copy)
      target = "@loader_path/../../../../#{bundlex_dir}/priv/shared/precompiled/#{bundle}/lib"

      copy
      |> Path.dirname()
      |> Path.join("*.so")
      |> Path.wildcard()
      |> Enum.filter(&("@loader_path/#{bundle}" in rpaths(&1)))
      |> Enum.each(&patch(&1, ["-rpath", "@loader_path/#{bundle}", target]))
    end)
  end

  defp referenced_names(file) do
    {out, 0} = System.cmd("otool", ["-L", file])
    Regex.scan(~r/@rpath\/(\S+)/, out, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end

  defp rpaths(file) do
    {out, 0} = System.cmd("otool", ["-l", file])
    Regex.scan(~r/LC_RPATH\n.*\n\s+path (\S+)/, out, capture: :all_but_first) |> List.flatten()
  end

  defp patch(file, args) do
    {_out, 0} = System.cmd("install_name_tool", args ++ [file], stderr_to_stdout: true)
    {_out, 0} = System.cmd("codesign", ["-s", "-", "-f", file], stderr_to_stdout: true)
  end

  defp dir_size(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end

  defp mb(bytes), do: "#{div(bytes, 1_000_000)} MB"
end
