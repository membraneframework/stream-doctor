# stream-doctor daemon

The Mix project behind the `stream-doctor` binary. See the
[root README](../README.md) for what it does and how to use it.

## Running from source

Needs Elixir 1.19+ and ffmpeg on the PATH.

```sh
mix deps.get
mix run --no-halt
```

This starts the daemon on port 4040 (`PORT` to change it). Connect with
`session({ daemonUrl: "http://localhost:4040" })` from the TypeScript SDK,
so no binary is needed for development.

## Standalone binary

`mix release` wraps the app with [Burrito](https://github.com/burrito-elixir/burrito)
into a single executable for the current machine, the same one the npm
packages ship. Point the check at it with `session({ binary: ... })`, or start
it by hand with `PORT=4040 burrito_out/stream_doctor_<target>` and connect with
`session({ daemonUrl: "http://localhost:4040" })`, where the target is
`macos_arm`, `linux_arm` or `linux_x86` (see `mix.exs`).

Building needs Elixir and Zig 0.16.0 on the PATH. If Burrito has no prebuilt
ERTS for your OTP version or platform, run `rel/pack_host_erts.sh` once first.
It packs the host's own ERTS into the layout Burrito expects.

The Membrane plugins share one copy of the precompiled FFmpeg bundle through
symlinks in their `priv` directories. `mix release` follows those links and
copies the bundle once per plugin, which would bloat the binary. To avoid this,
a custom release step (`Symlinks` in `mix.exs`) deletes the copies and writes
the list of links to `rel/burrito_plugin/symlinks.zon`. Burrito's payload
format cannot store symlinks, so the Burrito plugin
`rel/burrito_plugin/symlinks.zig` reads that list and recreates the links on
the target machine when the binary unpacks itself. That happens on the first
run, into `~/Library/Application Support/.burrito` on macOS and
`$XDG_DATA_HOME/.burrito` (default `~/.local/share/.burrito`) on Linux.
