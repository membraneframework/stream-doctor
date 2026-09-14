# StreamDoctor

Measures the audio/video drift of a live stream, end to end. Built on the
[Membrane Framework](https://membrane.stream).

StreamDoctor takes a media file, encodes the stream position into its audio
(a sequence of tones) and video (a frame-number bar at the bottom of each
frame), and publishes the result over RTMP. A viewer reads the HLS playlist the
infrastructure produces, decodes both markers and compares them against the
tracks' timestamps. The difference is the drift, positive when the audio is
late.

## Try it

Requires ffmpeg, python3, Node 24+ and macOS (Apple Silicon) or Linux.

On macOS the daemon also needs Homebrew's OpenSSL 3:

```sh
brew install openssl@3
```

The precompiled ffmpeg it bundles expects `libssl.3.dylib` in
`/opt/homebrew/lib` (or on `DYLD_FALLBACK_LIBRARY_PATH`). The daemon checks for
it at startup and exits with that instruction when it is missing.

```sh
npm install stream-doctor          # once: brings the daemon binary for this platform
examples/working_infra.sh         # terminal 1: a local RTMP -> HLS pipeline
node sdks/ts/examples/av_drift.ts # terminal 2: prints the drift, then PASS or FAIL
```

The daemon (a Mix project) lives in `daemon/`, the SDKs in `sdks/<language>/`.

`buggy_infra.sh` is the same pipeline with the audio delayed by 500 ms, which
the check should catch. The file to stream is the only argument of the check,
`test.mp4` by default.

## API

The binary listens on port 4040 (`PORT` to change it) and speaks JSON:

* `POST /streamer` `{"input": "test.mp4", "rtmp_url": "rtmp://..."}`,
  `GET /streamer`, `DELETE /streamer`,
* `POST /viewers` `{"hls_url": "https://....m3u8"}`, `GET /viewers/:id`,
  `DELETE /viewers/:id`,
* `GET /status`.

A viewer reports the drift under `metrics.av_drift.drift_ms`.
The `stream-doctor` npm package wraps the endpoints for scripts and brings the
binary along, as an optional dependency on `@stream-doctor/<platform>`:

```sh
npm install stream-doctor
```

```ts
import * as stream_doc from "stream-doctor";

const session = await stream_doc.session(); // spawns the bundled binary if nothing listens
// the daemon logs to session.logFile and quits when this process dies
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
// ... let it measure ...
const metrics = await viewer.stop();
```

`npm ci && npm run lint && npm test` in `sdks/ts` checks the client, as CI
does. To release, bump `version` in `sdks/ts/package.json` and push a matching
`vX.Y.Z` tag: the
Release workflow builds the binary per platform, then publishes the platform
packages and the wrapper (it needs an `NPM_TOKEN` repository secret).

## Standalone binary

`mix release` in `daemon/` wraps the app with [Burrito](https://github.com/burrito-elixir/burrito)
into a single executable for the current machine, the same one the npm
packages ship. Point the check at it with `session({ binary: ... })`, or start
it by hand with `PORT=4040 daemon/burrito_out/stream_doctor_macos_arm`.

It needs Elixir and Zig 0.16.0 on the PATH. Two release steps keep the binary small:
`daemon/rel/symlinks.exs` restores the symlinks through which every Membrane plugin
shares one copy of the precompiled FFmpeg bundle (`mix release` copies them as
full files, one per plugin), and `daemon/rel/burrito_plugin/plugin.zig` recreates
those links on the target machine, because Burrito's payload format cannot
carry symlinks. No binary patching is involved. If Burrito has no prebuilt
ERTS for your OTP, run `daemon/rel/pack_host_erts.sh` once first. The binary unpacks
itself into `~/Library/Application Support/.burrito` on the first run. For now
it only boots from the dev shell, because two NIFs still find OpenSSL through
`DYLD_LIBRARY_PATH`; that and the other open threads are tracked in `daemon/TODO.md`.
