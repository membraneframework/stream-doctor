# StreamDoctor

[![npm](https://img.shields.io/npm/v/stream-doctor.svg)](https://www.npmjs.com/package/stream-doctor)
[![CI](https://github.com/membraneframework-labs/stream_doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/membraneframework-labs/stream_doctor/actions/workflows/ci.yml)

Automated end-to-end testing for video infrastructure.

> **Status: early proof of concept.** This repository shows the core idea
> working on a single RTMP to HLS scenario with a single metric, the
> audio/video drift. It is a preview of the approach, not a finished product.
> The planned scope, including synthetic sources, a wider set of metrics,
> chaos testing (packet loss, bandwidth limits, jitter), more ingest and
> playback protocols, and SDKs for popular test runners, is described in
> [issue #1](https://github.com/membraneframework-labs/stream_doctor/issues/1).
> Feedback on it is welcome.

> Join the conversation in
> [discussion #16](https://github.com/membraneframework-labs/stream_doctor/discussions/16).

StreamDoctor publishes a stream into your pipeline, watches what comes out the
other end and turns the comparison into metrics you can assert on. The goal is
that regressions in sync, latency, frame delivery or playback quality get
caught by CI, not by someone clicking through a list of manual checks before a
release.

Built on the [Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox).

## The idea

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

## Try it

Requires ffmpeg, python3, Node 20+ and macOS (Apple Silicon) or Linux.

```sh
npm install stream-doctor  # brings the daemon binary for this platform
examples/working_infra.sh # a local RTMP -> HLS pipeline to measure against
```

Then run a script like the one above against it. `examples/buggy_infra.sh` is
the same pipeline with the audio delayed by 500 ms, which the check should
catch.

`session()` spawns the daemon bundled with the npm package on a free port,
`session({ port })` picks the port and `session({ binary })` the executable.
To use a daemon you started yourself, pass `session({ server: "http://..." })`
or set `STREAM_DOCTOR_SERVER`, then nothing is spawned.

The daemon (a Mix project) lives in `daemon/`, see its
[README](daemon/README.md) for building it from source. The SDKs live in
[`sdks/`](sdks/), currently only [TypeScript](sdks/ts/).

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
