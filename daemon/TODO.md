# Release shape: loose threads

Context: `rel/symlinks.exs` + `rel/burrito_plugin/plugin.zig` replace the old
otool/install_name_tool/codesign rewriting (`rel/slim.exs`). They restore the
symlinks that `mix release` dereferences and that Burrito's archiver cannot
carry, so NIF rpaths resolve unchanged. What is still open to get the binary
into its final shape:

## Correctness / portability

- [ ] **OpenSSL is linked by absolute path.** `ex_dtls` and `ex_libsrt` resolve
      `openssl` through pkg-config only, so their NIFs carry
      `/nix/store/.../libssl.3.dylib` (or `/opt/homebrew/...` on a Homebrew
      machine). The precompiled `libsrt` / `libsrtp2` reference
      `@rpath/libssl.3.dylib` and the only rpath that could satisfy it is the
      `/opt/homebrew/lib` bundlex adds. On any other machine SRT and WebRTC fail
      to load. **Verified 2026-09-09: the binary built here does not boot
      outside the dev shell** (`on_load_function_failed ExLibSRT.Native.Nif`,
      dyld: `Library not loaded: @rpath/libssl.3.dylib`, referenced from the
      precompiled `libsrt.1.5.4.dylib`, tried only the bundle dir and
      `/opt/homebrew/lib`). `../shell.nix` exports `DYLD_LIBRARY_PATH` to the
      nix OpenSSL, which is why it works from the dev shell; it was the same
      with the old `rel/slim.exs`. Fix at link time (a precompiled/bundled
      OpenSSL provider for those packages, or a bundlex `os_deps` override),
      not at release time. Until then the release step should at least
      *detect* absolute `/nix`, `/opt`, `/usr/local` references in
      `*.so`/`*.dylib` and fail loudly (needs `otool -L` / `readelf -d`,
      read-only).
- [ ] **Burrito debug builds break on the second run** (`debug: true` /
      `BURRITO_DEBUG`): the wrapper wipes the install dir *after* the plugin
      created the links. Prod builds only. Verified in `burrito_symlink_demo`.
- [ ] **The plugin depends on undocumented Burrito internals**: plugin runs
      before `do_payload_install`, `create_dirs` tolerates existing dirs, no file
      in the payload at a link path. Re-check `deps/burrito/src/wrapper.zig` and
      `archiver.zig` on every Burrito upgrade; the Zig std API also churns
      (0.15 -> 0.16 broke everything).
- [ ] **Upstream the real fix**: a symlink record in Burrito's FOILZ format
      (`src/archiver.zig`, pack + unpack, ~40 lines each side; Zig's `std.tar`
      has `writeLink` if they prefer switching). Use `burrito_symlink_demo` as
      the repro. When merged: delete `plugin.zig` and the `plugin:` option, keep
      `rel/symlinks.exs` as is (it already recreates real links in the release
      dir). Boombox's `restore_symlinks` starts working under Burrito too.

## Size

- [ ] **Prune bundle libraries the NIFs never load.** The macOS ffmpeg bundle is
      a repackaged Homebrew closure (OpenEXR, SDL2, X11, SvtAv1, FLAC, 461
      entries): 132 MB unique, of which only ~53 MB (69 of 192 dylibs) is
      reachable from any NIF via `otool -L`. Optional release step: walk the
      closure from every `*.so`, delete the rest. Read-only tooling
      (`otool`/`readelf`), no rewriting. Same idea upstream in
      membraneframework-precompiled would help every Membrane user.
- [ ] **Measure the wrapper, not just `lib/`.** xz (64 MiB dictionary) dedupes
      byte-identical copies that sit close together, so the demo's binary did
      not shrink at all; stream_doctor's five ffmpeg copies were far apart so it
      should. Record before/after of `burrito_out/*` and of the install dir.
- [ ] `priv/bundlex/nif/*_obj` (object files, ~3 MB total) and the bundles'
      `pkgconfig/`, `bin/`, `doc/`, `man/` dirs could be dropped too.

## Linux (untested)

- [ ] bundlex uses `$ORIGIN/<bundle>` rpaths, so the same links work; nothing
      platform-specific in the step. But: the Linux ffmpeg bundle (BtbN build
      repacked on a Mac) has **zero symlinks** and ships each SONAME alias as a
      full 74 MB copy plus AppleDouble `._*` junk. `dedupe_bundles/1` handles the
      copies by content hash; the `._*` files still need deleting.
- [ ] Burrito's prebuilt Linux ERTS is musl-based; glibc-linked NIFs (bundlex
      output on a glibc host) will not load against it. Expect to need a glibc
      `custom_erts` (see the Vix guide in burrito#190).

## Build environment

- [ ] **ERTS**: Burrito fetches a prebuilt ERTS for the OTP running
      `mix release`; `../shell.nix` pins OTP 27.3.4.16 because newer patch
      releases 404 on Beam Machine. Outside that shell (e.g. OTP 29.0.6),
      `rel/pack_host_erts.sh` packs the host OTP and `mix.exs` uses it as
      `custom_erts` when the version matches. Host == target only. Decide which
      of the two is the supported path.
- [ ] Only `macos_arm` is targeted. Cross-building is out until the ERTS and
      Linux points above are settled.
- [ ] `boombox` has the identical problem and a weaker fix; consider sharing
      `rel/symlinks.exs` with it (or contributing it to bundlex as a documented
      release step, alongside the "second rpath into `bundlex-<vsn>`" idea that
      would remove the per-plugin links altogether).
