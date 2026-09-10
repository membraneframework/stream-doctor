// Client for the stream_doctor server. `session({ binary })` spawns the
// binary when no server is listening; `session.close()` stops it.

import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";

const DEFAULT_SERVER = "http://localhost:4040";

export type Status =
  "streaming" | "receiving" | "waiting_for_playlist" | "ended" | "failed" | "stopped";

export interface StreamerStatus {
  input: string;
  rtmp_url: string;
  status: Status;
  error: string | null;
  frames_sent: number;
}

export interface AvDrift {
  drift_ms: number | null;
  frame_duration_ms: number | null;
  latest_samples: number[];
}

export interface Metrics {
  av_drift?: AvDrift;
  error?: string;
}

export interface ViewerStatus {
  id: string;
  hls_url: string;
  status: Status;
  error: string | null;
  metrics: Metrics;
}

export interface ServerStatus {
  streamer: StreamerStatus | null;
  viewers: ViewerStatus[];
}

async function api<T>(
  method: string,
  path: string,
  body: object | null,
  server: string
): Promise<T> {
  let res: Response;
  try {
    res = await fetch(server + path, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (e) {
    throw new Error(
      `${method} ${path}: cannot reach ${server} (is the server running?): ${(e as Error).message}`
    );
  }
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}: ${text}`);
  return JSON.parse(text);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const TERMINAL_STATUSES: Status[] = ["ended", "failed", "stopped"];

export async function session({
  server = DEFAULT_SERVER,
  binary,
}: { server?: string; binary?: string } = {}): Promise<Session> {
  try {
    await api("GET", "/status", null, server);
    return new Session(server, null);
  } catch (e) {
    if (!binary) throw e;
  }
  return new Session(server, await spawnServer(binary, server));
}

async function spawnServer(binary: string, server: string): Promise<ChildProcess> {
  if (!fs.existsSync(binary)) {
    throw new Error(`${binary} not found, build it with: MIX_ENV=prod mix release`);
  }
  console.log(`starting ${binary}`);
  // own process group, so that killing the burrito launcher takes the BEAM with it
  const child = spawn(binary, [], { stdio: ["ignore", "inherit", "inherit"], detached: true });
  for (const deadline = Date.now() + 120_000; Date.now() < deadline;) {
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
  server: string;
  child: ChildProcess | null;

  constructor(server: string, child: ChildProcess | null) {
    this.server = server;
    this.child = child;
  }

  publish(rtmpUrl: string, { file = "test.mp4" }: { file?: string } = {}): Streamer {
    const ready = api<StreamerStatus>(
      "POST",
      "/streamer",
      { input: file, rtmp_url: rtmpUrl },
      this.server
    );
    return new Streamer(this.server, ready);
  }

  async watch(hlsUrl: string): Promise<Viewer> {
    const { id } = await api<ViewerStatus>("POST", "/viewers", { hls_url: hlsUrl }, this.server);
    return new Viewer(this.server, id);
  }

  status(): Promise<ServerStatus> {
    return api("GET", "/status", null, this.server);
  }

  close(): Promise<void> {
    const child = this.child;
    if (!child || child.exitCode !== null || child.pid === undefined) return Promise.resolve();
    const pid = child.pid;
    return new Promise((resolve) => {
      setTimeout(() => process.kill(-pid, "SIGKILL"), 5000).unref();
      child.once("exit", () => resolve());
      process.kill(-pid, "SIGTERM");
    });
  }
}

class Streamer {
  server: string;
  ready: Promise<StreamerStatus>;

  constructor(server: string, ready: Promise<StreamerStatus>) {
    this.server = server;
    this.ready = ready;
    ready.catch(() => {});
  }

  status(): Promise<StreamerStatus> {
    return this.ready.then(() => api("GET", "/streamer", null, this.server));
  }

  async waitUntilLive({
    timeoutMs = 60_000,
    intervalMs = 250,
  }: { timeoutMs?: number; intervalMs?: number } = {}): Promise<StreamerStatus> {
    await this.ready;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const streamer = await api<StreamerStatus>("GET", "/streamer", null, this.server);
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

  async stop(): Promise<StreamerStatus> {
    await this.ready;
    return api("DELETE", "/streamer", null, this.server);
  }
}

class Viewer {
  server: string;
  id: string;

  constructor(server: string, id: string) {
    this.server = server;
    this.id = id;
  }

  status(): Promise<ViewerStatus> {
    return api("GET", `/viewers/${this.id}`, null, this.server);
  }

  async metrics(): Promise<Metrics> {
    const { metrics } = await this.status();
    return metrics;
  }

  async waitUntilDone({
    intervalMs = 1000,
    onUpdate,
  }: {
    intervalMs?: number;
    onUpdate?: (viewer: ViewerStatus) => void;
  } = {}): Promise<ViewerStatus> {
    for (;;) {
      const viewer = await this.status();
      onUpdate?.(viewer);
      if (TERMINAL_STATUSES.includes(viewer.status)) return viewer;
      await sleep(intervalMs);
    }
  }

  async stop(): Promise<Metrics> {
    const { metrics } = await api<ViewerStatus>("DELETE", `/viewers/${this.id}`, null, this.server);
    return metrics;
  }
}

export type { Session, Streamer, Viewer };
