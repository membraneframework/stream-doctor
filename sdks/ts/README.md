# stream-doctor

Measures the audio/video drift of a live stream, end to end. This package is
the TypeScript client for the [StreamDoctor](https://github.com/membraneframework-labs/stream_doctor)
daemon and brings the daemon binary along, as an optional dependency on
`@stream-doctor/<platform>` (macOS arm64, Linux x64 and arm64).

StreamDoctor takes a media file, encodes the stream position into its audio
(a sequence of tones) and video (a frame-number bar at the bottom of each
frame), and publishes the result over RTMP. A viewer reads the HLS playlist the
infrastructure under test produces, decodes both markers and compares them
against the tracks' timestamps. The difference is the drift, positive when the
audio is late.

## Install

```sh
npm install stream-doctor
```

Requires Node 20+. On macOS the daemon also needs Homebrew's OpenSSL 3
(`brew install openssl@3`): its precompiled ffmpeg expects `libssl.3.dylib`
in `/opt/homebrew/lib` or on `DYLD_FALLBACK_LIBRARY_PATH`, and the daemon
exits with that instruction when it is missing.

## Usage

```ts
import * as stream_doc from "stream-doctor";

const session = await stream_doc.session(); // spawns the bundled binary if nothing listens
// the daemon logs to session.logFile and quits when this process dies
const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
const viewer = await session.watch(hlsUrl);
await streamer.waitUntilLive();
// ... let it measure ...
const metrics = await viewer.stop();
console.log(metrics.av_drift?.drift_ms);
```

`session({ server, binary })` connects to a daemon already listening on
`server` (`http://localhost:4040` by default), otherwise it starts one from
`binary` or the bundled package. `session.close()` stops the daemon it
started.

A `Streamer` has `status()`, `waitUntilLive({ timeoutMs, intervalMs })` and
`stop()`. A `Viewer` has `status()`, `metrics()`,
`waitUntilDone({ intervalMs, onUpdate })` and `stop()`, which returns the
final metrics. Both are thin wrappers over the daemon's JSON API, described in
the repository README.

## License

Apache-2.0, Copyright 2026 [Software Mansion](https://swmansion.com).
