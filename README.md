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

Implementation: `StreamDoctor.Bar` (geometry/draw/decode, pure functions on I420
payloads), `StreamDoctor.OverlayFilter` (Membrane filter drawing the bar),
`StreamDoctor.DetectorSink` (Membrane sink reading it back).

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

Implementation: `StreamDoctor.Tone` (pure encode/generate/decode),
`StreamDoctor.AudioMarkerFilter`, `StreamDoctor.AudioDetectorSink`.

## Pipelines

**Sender** (`StreamDoctor.SenderPipeline`):

```
Boombox.Bin (MP4 → raw video) → OverlayFilter → H264.FFmpeg.Encoder (2s GOP)
  → H264.Parser (avc1) → Realtimer → RTMP.Sink
Boombox.Bin (raw audio) → AudioMarkerFilter → Transcoder (AAC) → Realtimer ↗
```

The audio marker is added when the input has an audio track. Boombox is used
for reading and demuxing; RTMP output goes through `membrane_rtmp_plugin`
(Boombox currently supports RTMP only as input). The H264 encoder uses a short
GOP (60 frames) — live-streaming ingests such as Amazon IVS disconnect streams
with sparse keyframes.

**Receiver** (`StreamDoctor.ReceiverPipeline`):

```
Boombox.Bin ({:hls, url} → raw video) → DetectorSink
Boombox.Bin (raw audio) → AudioDetectorSink
```

## Running

```sh
mix deps.get

# 1. stream a file with the overlay to RTMP
mix stream_doctor.send input.mp4 rtmp://server:1935/app/stream_key

# 2. read frame numbers back from HLS
mix stream_doctor.read https://server/path/index.m3u8

# 3. measure end-to-end latency (send + read in one process)
mix stream_doctor.latency input.mp4 rtmp://server:1935/app/key https://server/path/index.m3u8
```

`stream_doctor.send` paces the stream to real time (needed for live-streaming
servers); pass `--no-realtime` to push as fast as possible. The reader prints
`frame N` per video frame (or `decode error: ...`).

## Latency measurement

`mix stream_doctor.latency INPUT RTMP_URL HLS_URL` runs the sender and the
receiver in one BEAM node and prints, for every video frame,
`frame N: latency X ms` — the time between the frame (identified by its bar
counter) leaving the sender and being decoded by the receiver.

The send timestamp is captured by `StreamDoctor.SendProbe`, a transparent
filter placed right before the RTMP sink (after real-time pacing), so encoding
and pacing delays don't inflate the result; the receive timestamp is captured
in the `on_frame` callback of `StreamDoctor.DetectorSink`. Both timestamps
come from the same monotonic clock, so there is no clock-synchronization
error — the measured latency covers the RTMP ingest, the server's HLS
packaging, playlist/segment polling and decoding. The receiver is started
once the HLS playlist exists and lists at least one segment.

From code: `StreamDoctor.Latency.measure(input, rtmp_url, hls_url, opts)` —
pass `on_latency: fn %{frame: n, latency_ms: ms} -> ... end` to consume the
measurements programmatically.

## HTTP server + JS client

`mix stream_doctor.server [--port 4040]` exposes the same measurement over
HTTP (see `StreamDoctor.Api`): `POST /streamer` starts the sender,
`POST /viewers` starts a viewer (many can watch at once), `GET /viewers/:id`
returns its `pure_latency_ms` (rolling minimum = pure server latency) and the
latest per-frame samples, `GET /status` returns everything, `DELETE` stops.

`latency_client.mjs` wraps these endpoints for JS
(`startStreamer`/`startViewer`/`getViewer`/`watchLatency`, plus the
one-call `measureLatency({rtmpUrl, hlsUrl})`). `create_livestream.mjs` uses it
automatically: after creating the Firework livestream it starts the streamer
and a viewer through the server and logs the latency (falling back to printing
the manual `mix stream_doctor.latency` command when the server isn't running).

## Using from code (e.g. on an HTTP request)

Both entry points are plain functions starting a supervised Membrane pipeline,
so they can be called from a Phoenix controller / Plug handler:

```elixir
# fire-and-forget; returns the pipeline pid
pipeline = StreamDoctor.stream_with_overlay("input.mp4", "rtmp://...")

pipeline =
  StreamDoctor.read_frame_numbers("https://.../index.m3u8",
    on_frame: fn
      {:ok, n} -> IO.puts("frame #{n}")
      {:error, reason} -> IO.puts("error: #{inspect(reason)}")
    end
  )

# optionally block until the pipeline finishes (end of stream)
StreamDoctor.await(pipeline)
```

Note: `stream_with_overlay/2,3` and `read_frame_numbers/1,2` link the pipeline
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

# terminal 2: send
mix stream_doctor.send test.mp4 rtmp://127.0.0.1:1935/live/test

# terminal 3: serve HLS and read it back
python3 -m http.server 8123 -d /tmp/hls &
mix stream_doctor.read http://127.0.0.1:8123/index.m3u8
```

## Requirements

* Elixir ~> 1.15, Erlang/OTP
* native deps of Membrane FFmpeg-based plugins (H264 decode/encode, RTMP) —
  installed automatically via precompiled bundles or built with `pkg-config`ed
  FFmpeg
