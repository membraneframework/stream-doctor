# StreamDoctor

Measures the audio/video drift of a live stream, end to end. Built on the
[Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox).

StreamDoctor takes a media file, encodes the stream position into its audio
(a sequence of tones) and video (a frame-number bar at the bottom of each
frame), and publishes the result over RTMP. A viewer reads the HLS playlist the
infrastructure produces, decodes both markers and compares them against the
tracks' timestamps. The difference is the drift, positive when the audio is
late.

## Try it

Requires Elixir, Zig 0.16.0, ffmpeg, python3, Node 24+ and macOS.

```sh
mix deps.get
MIX_ENV=prod mix release          # once: builds burrito_out/stream_doctor_macos_arm
examples/working_infra.sh         # terminal 1: a local RTMP -> HLS pipeline
node examples/av_drift.ts         # terminal 2: prints the drift, then PASS or FAIL
```

`buggy_infra.sh` is the same pipeline with the audio delayed by 200 ms, which
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
`client/stream_doctor.ts` wraps the endpoints for scripts:

```ts
import * as stream_doc from "./client/stream_doctor.ts";

const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
// ... let it measure ...
const metrics = await viewer.stop();
```

`npm ci && npm run lint && npm test` checks the client, as CI does.
