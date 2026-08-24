# StreamDoctor

Elixir project based on [Membrane Framework](https://membrane.stream) and
[Boombox](https://hexdocs.pm/boombox) that:

1. reads a media file (e.g. MP4), draws a machine-readable **frame-number bar**
   on the bottom of the video and streams it to a given **RTMP** URL,
2. reads an **HLS** playlist, decodes the video and restores the frame number
   from the bar in every frame.

## The bar

A black strip spanning the whole width at the bottom of the frame, containing
17 squares (left to right):

| squares | meaning                                                        |
| ------- | -------------------------------------------------------------- |
| 0       | always white — reference for the "1"/white level                |
| 1       | always black — reference for the "0"/black level                |
| 2–15    | 14 data bits of the frame number, MSB first (white = 1)         |
| 16      | even-parity bit over the data bits                              |

Frame numbers start at 0 and wrap at 2¹⁴ = 16384. The geometry is derived
deterministically from the resolution (square side ≈ width/24), so the reader
reconstructs it from the stream format alone — no side channel needed. The two
reference squares let the reader compute the white/black threshold per frame,
and the parity bit rejects corrupted reads. Reading averages the central area
of each square, which makes the code robust to H.264 compression artifacts.

Implementation: `StreamDoctor.Probe.VideoMarkerEncoder` (Membrane filter
drawing the bar), `StreamDoctor.Probe.VideoMarkerDecoder` (Membrane sink
reading it back); the bar geometry/draw/decode itself lives in the private
`StreamDoctor.Probe.Bar`.

## The audio marker

The audible counterpart of the bar. The audio stream is divided into **30 ms
symbols**; symbol number = stream position / 30 ms, wrapping at 2⁷ = 128
(a 3.84 s cycle). Each symbol number is encoded as presence/absence of pure
tones in the spectrum:

| frequency        | meaning                                             |
| ---------------- | --------------------------------------------------- |
| 500 Hz           | reference tone, always present                      |
| 1000–4000 Hz (every 500 Hz) | 7 data bits, MSB first (tone present = 1) |
| 4500 Hz          | even-parity bit over the data bits                  |
| 250–4750 Hz (every 500 Hz, between the tones) | guard bins — never emitted, measure the local noise floor |

All frequencies are multiples of 1/30 ms ≈ 33.3 Hz, so every symbol contains a
whole number of cycles of each tone — no clicks at symbol boundaries and each
tone lands in a single DFT bin. The reader measures tone powers with the
Goertzel algorithm over the inner ⅔ of the window. Each tone is compared
against its own neighbouring guard bins (±250 Hz), so the decision is a local
SNR test robust to spectral tilt (codecs and filters attenuate high
frequencies); a small fraction of the reference power serves as a sanity floor,
and the always-on reference must pass the same local contrast test for the
window to count as a marker. Since AAC priming shifts sample alignment, the
reader self-synchronizes by scanning offsets within one symbol and picking the
one where consecutive windows decode with valid parity and consecutive numbers.

The marker **replaces** the original audio content (content energy at the
marker frequencies would corrupt detection).

Implementation: `StreamDoctor.Probe.AudioMarkerEncoder`,
`StreamDoctor.Probe.AudioMarkerDecoder`; the tone encode/generate/decode
itself lives in the private `StreamDoctor.Probe.Tone`.

## Pipelines

**Sender** (`StreamDoctor.SenderPipeline`):

```
Boombox.Bin (MP4 → raw video) → VideoMarkerEncoder → H264.FFmpeg.Encoder (2s GOP)
  → H264.Parser (avc1) → Realtimer → RTMP.Sink
Boombox.Bin (raw audio) → AudioMarkerEncoder → Transcoder (AAC) → Realtimer ↗
```

The audio marker is added when the input has an audio track. Boombox is used
for reading and demuxing; RTMP output goes through `membrane_rtmp_plugin`
(Boombox currently supports RTMP only as input). The H264 encoder uses a short
GOP (60 frames) — live-streaming ingests such as Amazon IVS disconnect streams
with sparse keyframes.

**Receiver** (`StreamDoctor.ReceiverPipeline`):

```
Boombox.Bin ({:hls, url} → raw video) → VideoMarkerDecoder
Boombox.Bin (raw audio) → AudioMarkerDecoder
```

## Running

```sh
mix deps.get

# run the latency-measurement HTTP server
mix stream_doctor.server [--port 4040]
```

## Latency measurement

The sender and viewers run in one BEAM node; for every video frame the
latency is the time between the frame (identified by its bar counter) leaving
the sender and being decoded by a viewer.

The send timestamp is captured by `StreamDoctor.Probe.SendReporter`, a transparent
filter placed right before the RTMP sink (after real-time pacing), so encoding
and pacing delays don't inflate the result; the receive timestamp is captured
by `StreamDoctor.Probe.VideoMarkerDecoder` as it decodes each frame. Both timestamps
come from the same monotonic clock, so there is no clock-synchronization
error — the measured latency covers the RTMP ingest, the server's HLS
packaging, playlist/segment polling and decoding. A viewer is started
once the HLS playlist exists and lists at least one segment.

## HTTP server + JS client

`mix stream_doctor.server [--port 4040]` exposes the measurements over
HTTP (see `StreamDoctor.Api`): `POST /streamer` starts the sender,
`POST /viewers` starts a viewer (many can watch at once; the optional
`"metrics"` list selects which metrics it computes), `GET /viewers/:id`
returns its measurements under `metrics`, `GET /status` returns everything,
`DELETE` stops.

Measurements are implemented as composable `StreamDoctor.Metric` modules —
pure folds over timestamped events (frame sent/received, audio symbol
received, lifecycle). Each viewer/player session runs one
`StreamDoctor.Metric.Collector` process holding its registered metrics; the
probes report events straight to it (streamer send events are broadcast to
all collectors), and reports appear under the metric name:

* `latency` (`StreamDoctor.Metric.Latency`) — end-to-end frame latency,
  matched by the bar counter; per-segment batching for viewers, latest-frame
  for players,
* `ttff` (`StreamDoctor.Metric.TimeToFirstFrame`) — time from viewer request
  to playlist availability / first decoded frame / first audio symbol,
* `av_drift` (`StreamDoctor.Metric.AvDrift`) — audio/video desync: the
  difference between the media positions implied by the latest video and
  audio marker counters.

Adding a metric = one module implementing the behaviour plus a registry entry
in `StreamDoctor.Metric`; the server and API need no changes.

`stream_doctor.mjs` wraps these endpoints in a session-based JS API:

```js
import * as stream_doc from "./stream_doctor.mjs";

const session = await stream_doc.session();
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive(); // frames flowing into the RTMP sink
// ... let it measure ...
const metrics = await viewer.stop(); // { latency: {...}, ttff: {...}, av_drift: {...} }
```

Plus `viewer.metrics()` / `viewer.waitUntilDone({onUpdate})`,
`streamer.stop()`, and `session.watchPlayer(source, opts)` for screenshot-based
player latency. `create_livestream.mjs` uses it automatically: after creating
the Firework livestream it starts the streamer and a viewer through the server
and logs the latency (printing the stream and playback URLs when the server
isn't running).

## Using from code (e.g. on an HTTP request)

Both pipelines expose a `start_link` starting them supervised, so they can be
called from a Phoenix controller / Plug handler:

```elixir
# fire-and-forget; returns the pipeline pid
pipeline = StreamDoctor.SenderPipeline.start_link("input.mp4", "rtmp://...")

# a collector holding the metrics; the pipeline's probes report to it
{:ok, collector} =
  StreamDoctor.Metric.Collector.start_link([
    {StreamDoctor.Metric.Latency, []},
    {StreamDoctor.Metric.AvDrift, []}
  ])

pipeline =
  StreamDoctor.ReceiverPipeline.start_link("https://.../index.m3u8",
    collector: collector
  )

# read the measurements whenever
StreamDoctor.Metric.Collector.report(collector)
# => %{latency: %{latency_ms: ..., ...}, av_drift: %{drift_ms: ..., ...}}

# optionally block until the pipeline finishes (end of stream)
ref = Process.monitor(pipeline)

receive do
  {:DOWN, ^ref, :process, ^pipeline, _reason} -> :ok
end
```

Without a `:collector`, the receiver just logs each decoded frame number and
audio symbol.

Note: `SenderPipeline.start_link` and `ReceiverPipeline.start_link` link the pipeline
to the calling process. For HTTP-triggered runs you'll typically want to start
them under your own supervisor instead of the request process — e.g. via a
`Task.Supervisor` or by calling `Membrane.Pipeline.start/2` — so the pipeline
outlives the request.

## Local end-to-end test

With `ffmpeg` acting as the RTMP server that repackages to HLS:

```sh
# terminal 1: RTMP server → HLS
mkdir -p /tmp/hls
ffmpeg -y -listen 1 -f flv -i rtmp://127.0.0.1:1935/live/test \
  -c copy -f hls -hls_time 2 -hls_list_size 0 /tmp/hls/index.m3u8

# terminal 2: serve HLS
python3 -m http.server 8123 -d /tmp/hls

# terminal 3: run the server and drive it over HTTP
mix stream_doctor.server
curl -X POST localhost:4040/streamer \
  -H 'content-type: application/json' \
  -d '{"input": "test.mp4", "rtmp_url": "rtmp://127.0.0.1:1935/live/test"}'
curl -X POST localhost:4040/viewers \
  -H 'content-type: application/json' \
  -d '{"hls_url": "http://127.0.0.1:8123/index.m3u8"}'
curl localhost:4040/viewers/viewer-1
```

## Requirements

* Elixir ~> 1.15, Erlang/OTP
* native deps of Membrane FFmpeg-based plugins (H264 decode/encode, RTMP) —
  installed automatically via precompiled bundles or built with `pkg-config`ed
  FFmpeg
