# stream-doctor daemon

The Mix project behind the `stream-doctor` binary. See the
[root README](../README.md) for what it does and how to use it.

## Running from source

Needs Elixir 1.19+ and ffmpeg on the PATH.

```sh
mix deps.get
mix run --no-halt
```

This starts the daemon on port 4040 (`PORT` to change it). `session()` from
the TypeScript SDK connects to it when something already listens there, so no
binary is needed for development.

## Standalone binary

`mix release` wraps the app with [Burrito](https://github.com/burrito-elixir/burrito)
into a single executable for the current machine, the same one the npm
packages ship. Point the check at it with `session({ binary: ... })`, or start
it by hand with `PORT=4040 burrito_out/stream_doctor_<target>` and connect with
`session({ server: "http://localhost:4040" })`, where the target is
`macos_arm`, `linux_arm` or `linux_x86` (see `mix.exs`).

It needs Elixir and Zig 0.16.0 on the PATH. Two release steps keep the binary small:
`rel/symlinks.exs` restores the symlinks through which every Membrane plugin
shares one copy of the precompiled FFmpeg bundle (`mix release` copies them as
full files, one per plugin), and `rel/burrito_plugin/plugin.zig` recreates
those links on the target machine, because Burrito's payload format cannot
carry symlinks. No binary patching is involved. If Burrito has no prebuilt
ERTS for your OTP, run `rel/pack_host_erts.sh` once first. The binary unpacks
itself on the first run into `~/Library/Application Support/.burrito` on macOS
and `$XDG_DATA_HOME/.burrito` (default `~/.local/share/.burrito`) on Linux.
