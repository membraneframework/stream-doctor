# StreamDoctor

Automated end-to-end testing for live video infrastructure.

StreamDoctor publishes a reference stream into your pipeline, watches what
comes out the other end and turns the comparison into metrics you can assert
on. The goal is that regressions in sync, latency, frame delivery or playback
quality get caught by CI, not by someone clicking through a list of manual
checks before a release.

> **Status: early proof of concept.** This repository shows the core idea
> working on a single RTMP to HLS scenario. It is a preview of the approach,
> not a finished product. The planned scope, including synthetic sources, a
> wider set of metrics, chaos testing (packet loss, bandwidth limits, jitter),
> more ingest and playback protocols, and SDKs for popular test runners, is
> described in
> [issue #1](https://github.com/membraneframework-labs/stream_doctor/issues/1).
> Feedback on it is welcome.

Built on the [Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox).

## The idea

Tests are written the same way you already write browser tests. A session
groups a publisher and any number of viewers, the publisher streams marked
media into your infrastructure, and each viewer collects metrics from the
playback URL your product exposes:

```ts
import * as stream_doc from "./client/stream_doctor.ts";

const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
await streamer.waitUntilLive();

const viewer = await session.watch(hlsUrl);
// ... let it measure ...
const metrics = await viewer.stop();

expect(Math.abs(metrics.av_drift.drift_ms)).toBeLessThan(50);
```

The stream carries markers in both audio and video that identify each moment
of the source. Because a viewer can recover the original position from what
it receives, it can measure exactly what the pipeline did to the stream.

## Try it

Requires Elixir, Zig 0.16.0, ffmpeg, python3, Node 24+ and macOS.

```sh
mix deps.get
MIX_ENV=prod mix release          # builds burrito_out/stream_doctor_macos_arm
examples/working_infra.sh         # terminal 1: a local RTMP -> HLS pipeline
node examples/av_drift.ts         # terminal 2: runs a check, prints PASS or FAIL
```

`examples/buggy_infra.sh` is the same local pipeline with a deliberately
introduced fault, which the check should catch. Pass a path to the check to
stream your own file instead of `test.mp4`.

## HTTP API

The TypeScript client above starts the binary for you. If you prefer to drive
it directly, it listens on port 4040 (`PORT` to change it) and speaks JSON:

* `POST /streamer` `{"input": "test.mp4", "rtmp_url": "rtmp://..."}`,
  `GET /streamer`, `DELETE /streamer`,
* `POST /viewers` `{"hls_url": "https://....m3u8"}`, `GET /viewers/:id`,
  `DELETE /viewers/:id`,
* `GET /status`.

Metrics collected by a viewer are returned under `metrics`.
