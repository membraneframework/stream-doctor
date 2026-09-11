# StreamDoctor

> **Early proof of concept.** StreamDoctor is meant to be a tool that
> broadcasts a synthetic, marked stream through your video infrastructure and
> measures what happened to it along the way, so that problems like A/V drift,
> dropped frames or stalls get caught by CI instead of by a human clicking
> through a list of manual tests. Today it only does one thing: it measures the
> audio/video drift of an RTMP to HLS pipeline, end to end. Chaos testing, more
> metrics, more protocols and SDKs are planned. See the full vision and the
> roadmap in
> [issue #1](https://github.com/membraneframework-labs/stream_doctor/issues/1).

Built on the [Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox).

## How it works

StreamDoctor takes a media file, encodes the stream position into its audio (a
sequence of tones) and video (a frame-number bar at the bottom of each frame),
and publishes the result over RTMP. A viewer reads the HLS playlist your
infrastructure produces, decodes both markers and compares them against the
tracks' timestamps. The difference is the drift, positive when the audio is
late.

## Try it

Requires Elixir, Zig 0.16.0, ffmpeg, python3, Node 24+ and macOS.

```sh
mix deps.get
MIX_ENV=prod mix release          # builds burrito_out/stream_doctor_macos_arm
examples/working_infra.sh         # terminal 1: a local RTMP -> HLS pipeline
node examples/av_drift.ts         # terminal 2: prints the drift, then PASS or FAIL
```

`examples/buggy_infra.sh` is the same pipeline with the audio delayed by
200 ms, which the check should catch. The file to stream is the only argument
of the check, `test.mp4` by default.

## Using it from your own tests

`client/stream_doctor.ts` starts the binary for you and wraps its API:

```ts
import * as stream_doc from "./client/stream_doctor.ts";

const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
// ... let it measure ...
const metrics = await viewer.stop();
console.log(metrics.av_drift?.drift_ms);
```

## HTTP API

If you prefer to drive the binary directly, it listens on port 4040 (`PORT`
to change it) and speaks JSON:

* `POST /streamer` `{"input": "test.mp4", "rtmp_url": "rtmp://..."}`,
  `GET /streamer`, `DELETE /streamer`,
* `POST /viewers` `{"hls_url": "https://....m3u8"}`, `GET /viewers/:id`,
  `DELETE /viewers/:id`,
* `GET /status`.

A viewer reports the drift under `metrics.av_drift.drift_ms`.
