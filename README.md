# stream-doctor

[![npm](https://img.shields.io/npm/v/stream-doctor.svg)](https://www.npmjs.com/package/stream-doctor)
[![CI](https://github.com/membraneframework/stream-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/membraneframework/stream-doctor/actions/workflows/ci.yml)

Automated end-to-end testing for video infrastructure.

> **Status: early proof of concept.** This repository shows the core idea
> working on a single RTMP to HLS scenario with a single metric, the
> audio/video drift. It is a preview of the approach, not a finished product.
> The planned scope, including synthetic sources, a wider set of metrics,
> chaos testing (packet loss, bandwidth limits, jitter), more ingest and
> playback protocols, and SDKs for popular test runners, is described in
> [issue #1](https://github.com/membraneframework/stream-doctor/issues/1).
> Feedback on it is welcome.

> Join the conversation in
> [discussion #16](https://github.com/membraneframework/stream-doctor/discussions/16).

stream-doctor publishes a stream into your pipeline, watches what comes out the
other end and turns the comparison into metrics you can assert on. The goal is
that regressions in sync, latency, frame delivery or playback quality get
caught by CI, not by someone clicking through a list of manual checks before a
release.

Built on the [Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox).

The project consists of:

* the daemon, a Mix project in [`daemon/`](daemon/), see its
  [README](daemon/README.md) for building it from source,
* the SDKs in [`sdks/`](sdks/), currently only [TypeScript](sdks/ts/).

## Installation

Requires Node 20+.

```sh
npm install stream-doctor
```

This installs the TypeScript SDK. The SDK talks to the daemon, which does the
actual streaming and measuring, so you also need to make sure it is available.
There are three ways to do that.

### Precompiled daemon

On macOS (Apple Silicon), Linux (x86_64) and Linux (arm64) the daemon binary
is downloaded automatically along with the package, as an optional dependency
on `@stream-doctor/<platform>`. Nothing else is needed.

### Running the daemon from source

On other platforms, or to run the latest code, start the daemon from the Mix
project in [`daemon/`](daemon/). This needs Elixir 1.19+, see
[Running from source](daemon/README.md#running-from-source), then connect
with `session({ daemonUrl: "http://localhost:4040" })`.

### Building the daemon binary

To get a standalone executable like the precompiled ones, see
[Standalone binary](daemon/README.md#standalone-binary) and pass it with
`session({ binary })`.

## Getting started

Tests are written the same way you already write browser tests. A session
groups a publisher and any number of viewers, the publisher streams marked
media into your infrastructure, and each viewer collects metrics from the
playback URL your product exposes:

```ts
import * as stream_doc from "stream-doctor";

const session = await stream_doc.session(); // spawns the bundled daemon on a free port
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
await streamer.waitUntilLive();

const viewer = await session.watch(hlsUrl);
// ... let it measure ...
const metrics = await viewer.stop();

expect(Math.abs(metrics.av_drift.drift_ms)).toBeLessThan(50); // any test runner's assertion
```

The stream carries markers in both audio and video that identify each moment
of the source. Because a viewer can recover the original position from what
it receives, it can measure exactly what the pipeline did to the stream.

To try it against a local pipeline, start one of the examples (they need
ffmpeg and python3):

```sh
examples/working_infra.sh # a local RTMP -> HLS pipeline to measure against
```

Then run a script like the one above against it, for example
[`examples/av_drift.ts`](examples/av_drift.ts) with `node examples/av_drift.ts`.
`examples/buggy_infra.sh` is the same pipeline with the audio delayed by
500 ms, which the check should catch.

`session()` spawns the daemon bundled with the npm package on a free port,
`session({ port })` picks the port and `session({ binary })` the executable.
To use a daemon you started yourself, pass `session({ daemonUrl: "http://..." })`,
then nothing is spawned.

## HTTP API

The TypeScript client above starts the binary for you. If you prefer to drive
it directly, it listens on port 4040 (`PORT` to change it) and speaks JSON:

* `POST /streamer` `{"input": "test.mp4", "rtmp_url": "rtmp://..."}`,
  `GET /streamer`, `DELETE /streamer`,
* `POST /viewers` `{"hls_url": "https://....m3u8"}`, `GET /viewers/:id`,
  `DELETE /viewers/:id`,
* `GET /status`.

Metrics collected by a viewer are returned under `metrics`.

## Copyright and License

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=stream_doctor)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=stream_doctor)

Licensed under the [Apache License, Version 2.0](LICENSE)
