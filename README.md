# StreamDoctor

Measures A/V drift of a live stream. Membrane + Boombox.

Streams a file to RTMP with markers baked in (a frame-number bar at the bottom
of the video, tones in the audio), then reads the HLS output back and compares
where each track's marker sits against its timestamps.

## Markers

**Bar**: black strip, 17 squares. White ref, black ref, 14 bits of frame
number, parity. Wraps at 16384. Size follows the resolution, so the reader
needs nothing extra. `StreamDoctor.Probe.Video.MarkerEncoder` / `Video.MarkerDecoder`,
guts in `StreamDoctor.Probe.Video.Bar`.

**Tones**: 30 ms symbols, wraps at 128. 500 Hz always on, 1000..4000 Hz = 7
bits, 4500 Hz = parity. Detected with Goertzel against neighbouring guard
bins, so codec roll-off doesn't matter. Replaces the audio, doesn't mix.
`StreamDoctor.Probe.Audio.MarkerEncoder` / `Audio.MarkerDecoder`, guts in
`StreamDoctor.Probe.Audio.Tone`.

## Pipelines

```
Boombox.Bin → Video.MarkerEncoder → H264 encoder → parser → Realtimer → SendReporter → RTMP.Sink
Boombox.Bin → Audio.MarkerEncoder → AAC → Realtimer → SendReporter ↗

HLS Source → H264 decoder → Video.MarkerDecoder
HLS Source → AAC decoder → Audio.MarkerDecoder
```

`SendReporter` only counts frames going out, for "is it live yet". Keyframe
every 2 s because IVS drops you otherwise.

## Metrics

`StreamDoctor.Metric` modules, folds over events, one
`StreamDoctor.Collector` per viewer. Just one for now:

* `av_drift` - audio pts offset minus video pts offset, i.e. what a player
  syncing by timestamps would show. Positive = audio late.

## Running

```sh
mix deps.get
mix stream_doctor.server [--port 4040]

curl -X POST localhost:4040/streamer -H 'content-type: application/json' \
  -d '{"input": "test.mp4", "rtmp_url": "rtmp://..."}'
curl -X POST localhost:4040/viewers -H 'content-type: application/json' \
  -d '{"hls_url": "https://....m3u8"}'
curl localhost:4040/viewers/viewer-1
```

`GET /status` has everything. See `StreamDoctor.Api`.

`stream_doctor.mjs` wraps it:

```js
const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
const metrics = await viewer.stop();
```

From Elixir, `SenderPipeline.start_link/3` and `ReceiverPipeline.start_link/2`
(with a `:collector`) do the same. Both link to the caller.

## Local test

```sh
mkdir -p /tmp/hls
ffmpeg -y -listen 1 -f flv -i rtmp://127.0.0.1:1935/live/test \
  -c copy -f hls -hls_time 2 -hls_list_size 0 /tmp/hls/index.m3u8
python3 -m http.server 8123 -d /tmp/hls
```

then point the streamer at the rtmp URL and a viewer at
`http://127.0.0.1:8123/index.m3u8`. `node examples/av_drift.mjs` does this
for you and checks the drift metric with and without a 200 ms audio delay.

## Requirements

Elixir ~> 1.15, the usual Membrane native deps.
