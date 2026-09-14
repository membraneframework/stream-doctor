# StreamDoctor daemon

The Mix project behind the `stream-doctor` binary. See the
[root README](../README.md) for what it does and how to use it.

## Standalone binary

`mix release` wraps the app with [Burrito](https://github.com/burrito-elixir/burrito)
into a single executable for the current machine, the same one the npm
packages ship. Point the check at it with `session({ binary: ... })`, or start
it by hand with `PORT=4040 burrito_out/stream_doctor_macos_arm`.

It needs Elixir and Zig 0.16.0 on the PATH. Two release steps keep the binary small:
`rel/symlinks.exs` restores the symlinks through which every Membrane plugin
shares one copy of the precompiled FFmpeg bundle (`mix release` copies them as
full files, one per plugin), and `rel/burrito_plugin/plugin.zig` recreates
those links on the target machine, because Burrito's payload format cannot
carry symlinks. No binary patching is involved. If Burrito has no prebuilt
ERTS for your OTP, run `rel/pack_host_erts.sh` once first. The binary unpacks
itself into `~/Library/Application Support/.burrito` on the first run. For now
it only boots from the dev shell, because two NIFs still find OpenSSL through
`DYLD_LIBRARY_PATH`; that and the other open threads are tracked in `TODO.md`.
