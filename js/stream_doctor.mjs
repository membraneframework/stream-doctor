// JS client for the stream_doctor server (see README for the API).
//
//   const session = await stream_doc.session();          // server on :4040
//   const streamer = session.publish(rtmpUrl, { file: "test.mp4" });
//   await streamer.waitUntilLive();
//   const viewer = await session.watch(hlsUrl);
//   const { av_drift } = await viewer.metrics();          // any time
//   await viewer.stop(); await streamer.stop();

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

export async function session({ server = DEFAULT_SERVER } = {}) {
  await api("GET", "/status", null, server);
  return new Session(server);
}

class Session {
  constructor(server) {
    this.server = server;
  }

  publish(rtmpUrl, { file = "test.mp4" } = {}) {
    const ready = api("POST", "/streamer", { input: file, rtmp_url: rtmpUrl }, this.server);
    return new Streamer(this.server, ready);
  }

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
    this.ready = ready;
    ready.catch(() => {}); // reported by the awaiting methods instead
  }

  status() {
    return this.ready.then(() => api("GET", "/streamer", null, this.server));
  }

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

  async metrics() {
    const { metrics } = await this.status();
    return metrics;
  }

  async waitUntilDone({ intervalMs = 1000, onUpdate } = {}) {
    for (;;) {
      const viewer = await this.status();
      onUpdate?.(viewer);
      if (TERMINAL_STATUSES.includes(viewer.status)) return viewer;
      await sleep(intervalMs);
    }
  }

  async stop() {
    const { metrics } = await api("DELETE", `/viewers/${this.id}`, null, this.server);
    return metrics;
  }
}
