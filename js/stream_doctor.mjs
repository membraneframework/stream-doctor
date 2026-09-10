// Client for the stream_doctor server. `session({ binary })` spawns the
// binary when no server is listening; `session.close()` stops it.

import { spawn } from "node:child_process";
import fs from "node:fs";

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

export async function session({ server = DEFAULT_SERVER, binary } = {}) {
  try {
    await api("GET", "/status", null, server);
    return new Session(server, null);
  } catch (e) {
    if (!binary) throw e;
  }
  return new Session(server, await spawnServer(binary, server));
}

async function spawnServer(binary, server) {
  if (!fs.existsSync(binary)) {
    throw new Error(`${binary} not found, build it with: MIX_ENV=prod mix release`);
  }
  console.log(`starting ${binary}`);
  // own process group, so that killing the burrito launcher takes the BEAM with it
  const child = spawn(binary, [], { stdio: ["ignore", "inherit", "inherit"], detached: true });
  for (const deadline = Date.now() + 120_000; Date.now() < deadline; ) {
    if (child.exitCode !== null) throw new Error(`server exited with ${child.exitCode}`);
    await sleep(1000);
    try {
      await api("GET", "/status", null, server);
      return child;
    } catch {}
  }
  throw new Error("server didn't come up in 2 minutes");
}

class Session {
  constructor(server, child) {
    this.server = server;
    this.child = child;
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

  close() {
    const child = this.child;
    if (!child || child.exitCode !== null) return Promise.resolve();
    return new Promise((resolve) => {
      setTimeout(() => process.kill(-child.pid, "SIGKILL"), 5000).unref();
      child.once("exit", resolve);
      process.kill(-child.pid, "SIGTERM");
    });
  }
}

class Streamer {
  constructor(server, ready) {
    this.server = server;
    this.ready = ready;
    ready.catch(() => {});
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
