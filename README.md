# StreamDoctor

[![npm](https://img.shields.io/npm/v/stream-doctor.svg)](https://www.npmjs.com/package/stream-doctor)
[![CI](https://github.com/membraneframework-labs/stream_doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/membraneframework-labs/stream_doctor/actions/workflows/ci.yml)

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
npm install stream-doctor  # once: brings the daemon binary for this platform
examples/working_infra.sh # a local RTMP -> HLS pipeline to measure against
```

Then run a script like the one under [API](#api) against it.
`buggy_infra.sh` is the same pipeline with the audio delayed by 500 ms, which
the measurement should catch.

The daemon (a Mix project) lives in `daemon/`, the SDKs in `sdks/<language>/`.

## API

The binary listens on port 4040 (`PORT` to change it) and speaks JSON:

* `POST /streamer` `{"input": "test.mp4", "rtmp_url": "rtmp://..."}`,
  `GET /streamer`, `DELETE /streamer`,
* `POST /viewers` `{"hls_url": "https://....m3u8"}`, `GET /viewers/:id`,
  `DELETE /viewers/:id`,
* `GET /status`.

A viewer reports the drift under `metrics.av_drift.drift_ms`.
The [`stream-doctor`](https://www.npmjs.com/package/stream-doctor) npm package
(sources in `sdks/ts/`, usage in its README) wraps the endpoints for scripts
and brings the binary along, as an optional dependency on
`@stream-doctor/<platform>`:

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

Building the daemon into a single executable is described in
[`daemon/README.md`](daemon/README.md).

## Copyright and License

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=stream_doctor)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=stream_doctor)

Licensed under the [Apache License, Version 2.0](LICENSE)
