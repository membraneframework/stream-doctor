// JS client for the stream_doctor measurement server.
//
// Start the server first:
//   mix run --no-halt   (PORT=4040 by default)
//
// Usage:
//   import * as stream_doc from "./stream_doctor.mjs";
//
//   const session = await stream_doc.session();
//   const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
//   const viewer = await session.watch(hlsUrl);
//   await streamer.waitUntilLive();
//   // ... let it measure ...
//   const metrics = await viewer.stop();
//   // metrics: { av_drift: { drift_ms, ... } }

const DEFAULT_SERVER = "http://localhost:4040";

async function api(method, path, body, server) {
  let res;
  try {
    res = await fetch(server + path, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (e) {
    throw new Error(
      `${method} ${path}: cannot reach ${server} (is the server running?): ${e.message}`
    );
  }
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const TERMINAL_STATUSES = ["ended", "failed", "stopped"];

// Opens a session against a running server (verifies it is reachable).
export async function session({ server = DEFAULT_SERVER } = {}) {
  await api("GET", "/status", null, server);
  return new Session(server);
}

class Session {
  constructor(server) {
    this.server = server;
  }

  // Starts streaming `file` (a path on the server's machine) with the markers
  // to `rtmpUrl`. Returns a Streamer immediately; await streamer.waitUntilLive()
  // for the moment frames actually flow into the RTMP sink.
  publish(rtmpUrl, { file = "test.mp4" } = {}) {
    const ready = api("POST", "/streamer", { input: file, rtmp_url: rtmpUrl }, this.server);
    return new Streamer(this.server, ready);
  }

  // Starts a viewer of the HLS playlist.
  async watch(hlsUrl) {
    const { id } = await api("POST", "/viewers", { hls_url: hlsUrl }, this.server);
    return new Viewer(this.server, id);
  }

  status() {
    return api("GET", "/status", null, this.server);
  }
}

class Streamer {
  constructor(server, ready) {
    this.server = server;
    // surfaces the POST /streamer error on the awaited methods below instead
    // of as an unhandled rejection
    this.ready = ready;
    ready.catch(() => {});
  }

  status() {
    return this.ready.then(() => api("GET", "/streamer", null, this.server));
  }

  // Resolves once the streamer reports frames flowing into the RTMP sink
  // (frames_sent > 0), i.e. the RTMP handshake succeeded and media is live.
  async waitUntilLive({ timeoutMs = 60_000, intervalMs = 250 } = {}) {
    await this.ready;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const streamer = await api("GET", "/streamer", null, this.server);
      if (streamer.frames_sent > 0) return streamer;
      if (TERMINAL_STATUSES.includes(streamer.status)) {
        throw new Error(
          `streamer ${streamer.status} before going live${streamer.error ? `: ${streamer.error}` : ""}`
        );
      }
      if (Date.now() > deadline) throw new Error(`streamer not live within ${timeoutMs} ms`);
      await sleep(intervalMs);
    }
  }

  async stop() {
    await this.ready;
    return api("DELETE", "/streamer", null, this.server);
  }
}

class Viewer {
  constructor(server, id) {
    this.server = server;
    this.id = id;
  }

  status() {
    return api("GET", `/viewers/${this.id}`, null, this.server);
  }

  // Current measurements: { av_drift: {...} }.
  async metrics() {
    const { metrics } = await this.status();
    return metrics;
  }

  // Polls until the viewer reaches a terminal status, calling onUpdate with
  // the full viewer state on every poll. Resolves with the final viewer state.
  async waitUntilDone({ intervalMs = 1000, onUpdate } = {}) {
    for (;;) {
      const viewer = await this.status();
      onUpdate?.(viewer);
      if (TERMINAL_STATUSES.includes(viewer.status)) return viewer;
      await sleep(intervalMs);
    }
  }

  // Stops the viewer and resolves with its final metrics.
  async stop() {
    const { metrics } = await api("DELETE", `/viewers/${this.id}`, null, this.server);
    return metrics;
  }
}
