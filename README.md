# StreamDoctor

Measures A/V drift of a live stream. Membrane + Boombox.

Streams a file to RTMP with markers baked in (a frame-number bar on the
video, tones in the audio), reads the HLS output back and checks where each
track's marker sits against its timestamps. Positive drift = audio late.

## Try it

```sh
mix deps.get
mix stream_doctor.server          # terminal 1
examples/working_infra.sh         # terminal 2: ffmpeg RTMP -> HLS, passthrough
node examples/av_drift.mjs        # terminal 3: prints drift, PASS / FAIL
```

Then swap terminal 2 for `examples/buggy_infra.sh` (audio delayed 200 ms) and
run the check again. Needs ffmpeg, python3, node. Options: `--file`,
`--measure-s`, `--expect`, `--tolerance`.

Known wart: passthrough currently measures ~77 ms, not 0. That's our own
sender pipeline (the AAC encoder delay isn't compensated in the timestamps),
not the infra, so until that's fixed run the check with `--expect 77`. The
buggy infra lands at ~277 ms either way.

## API

`POST/GET/DELETE /streamer` with `{"input", "rtmp_url"}`, `POST /viewers`
with `{"hls_url"}`, `GET/DELETE /viewers/:id`, `GET /status`. Drift is under
`metrics.av_drift.drift_ms`. `stream_doctor.mjs` wraps it:

```js
const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
const metrics = await viewer.stop();
```

## How

**Bar**: 17 squares at the bottom of the frame, white ref, black ref, 14 bits
of frame number, parity. `StreamDoctor.Probe.Video`.

**Tones**: 30 ms symbols, 500 Hz ref, 1000..4000 Hz = 7 bits, 4500 Hz parity,
Goertzel against guard bins. Replaces the audio. `StreamDoctor.Probe.Audio`.

**Metric**: `StreamDoctor.Metric.AvDrift`, audio pts offset minus video pts
offset, i.e. what a timestamp-syncing player would show. Arrival times are
ignored on purpose.

```
Boombox.Bin → markers → encoders → Realtimer → RTMP.Sink
HLS Source → decoders → marker decoders → Collector
```
