# StreamDoctor

Measures the audio/video drift of a live stream, end to end. Built on the
[Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox).

The idea: instead of trusting whatever the streaming infrastructure reports,
send it a stream whose content is machine-readable and check what comes out
the other side. StreamDoctor takes a media file, replaces its audio with a
sequence of tones encoding the stream position and paints a small bar with the
frame number at the bottom of every video frame, then publishes the result over
RTMP. A viewer reads the HLS playlist the infrastructure produces, decodes both
markers and compares where each track's marker sits against the track's
timestamps. If the audio content has moved relative to the video content
somewhere along the way, the two offsets no longer agree, and the difference is
the drift. Positive drift means the audio is late.

Everything runs inside one Elixir node exposed over a small HTTP API, so a
streamer and any number of viewers can be driven from a script.

## Try it

You need Elixir, ffmpeg, python3 and node on your PATH, and a media file with
an audio track (`test.mp4` by default).

```sh
mix deps.get
mix stream_doctor.server          # terminal 1: the HTTP API on :4040
examples/working_infra.sh         # terminal 2: the infrastructure under test
node examples/av_drift.mjs        # terminal 3: the check
```

"Infra" stands in for whatever streaming platform you want to examine. The
helper scripts run a local one: ffmpeg listening for RTMP on port 1935 and
repackaging the stream to HLS, served by a Python static server on port 8123.
`working_infra.sh` passes the media through untouched, so the drift should be
close to zero. `buggy_infra.sh` delays the audio content by 200 ms on the way,
which the check should catch. Run the same check against both and compare.

The check publishes the file, starts a viewer, waits for the first drift
sample, keeps sampling for a while and finally prints PASS or FAIL. Options:

* `--file test.mp4` - the file to stream,
* `--measure-s 30` - how long to keep sampling after the first drift value,
* `--expect 0` - the drift you expect, in ms,
* `--tolerance 40` - how far from that is still a PASS, in ms.

## API

The server speaks JSON:

* `POST /streamer` with `{"input": "test.mp4", "rtmp_url": "rtmp://..."}`
  starts publishing, `GET /streamer` shows its status, `DELETE /streamer`
  stops it,
* `POST /viewers` with `{"hls_url": "https://....m3u8"}` starts a viewer and
  returns its `id`; `GET /viewers/:id` shows its status and measurements,
  `DELETE /viewers/:id` stops it,
* `GET /status` returns all of the above at once.

The drift is reported under `metrics.av_drift.drift_ms` of a viewer, together
with the recent samples it was computed from. `stream_doctor.mjs` wraps the
endpoints for scripts:

```js
import * as stream_doc from "./stream_doctor.mjs";

const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
// ... let it measure ...
const metrics = await viewer.stop();
```
