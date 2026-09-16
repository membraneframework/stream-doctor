import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import net, { type AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";

const LOG_FILE = path.join(os.tmpdir(), "stream_doctor.log");

const PLATFORM_PACKAGES: Record<string, string> = {
  "darwin-arm64": "@stream-doctor/darwin-arm64",
  "linux-arm64": "@stream-doctor/linux-arm64",
  "linux-x64": "@stream-doctor/linux-x64",
};

const TERMINAL_STATUSES: Status[] = ["ended", "failed", "stopped"];

/** Lifecycle state of a streamer or viewer. */
export type Status =
  "streaming" | "receiving" | "waiting_for_playlist" | "ended" | "failed" | "stopped";

/** State of the publisher, as reported by the daemon. */
export interface StreamerStatus {
  input: string;
  rtmp_url: string;
  status: Status;
  error: string | null;
  live: boolean;
}

/** Audio/video drift measured by a viewer, in milliseconds. */
export interface AvDrift {
  drift_ms: number | null;
  frame_duration_ms: number | null;
  latest_samples: number[];
}

/** Metrics collected by a viewer. */
export interface Metrics {
  av_drift?: AvDrift;
  error?: string;
}

/** State of a viewer, as reported by the daemon. */
export interface ViewerStatus {
  id: string;
  hls_url: string;
  status: Status;
  error: string | null;
  metrics: Metrics;
}

/** State of the whole daemon. */
export interface DaemonStatus {
  streamer: StreamerStatus | null;
  viewers: ViewerStatus[];
}

/** Spawns a daemon from `binary` (the bundled one by default) on `port` (a free one by default), or connects to a running one when `daemonUrl` is set. */
export async function session({
  daemonUrl,
  binary,
  port,
}: { daemonUrl?: string; binary?: string; port?: number } = {}): Promise<Session> {
  if (daemonUrl) {
    if (binary !== undefined || port !== undefined) {
      throw new Error(
        "`daemonUrl` connects to a running daemon, it cannot be combined with `binary` or `port`"
      );
    }
    await api("GET", "/status", null, daemonUrl);
    return new Session(daemonUrl, null);
  }
  let installDir: string | undefined;
  if (!binary) {
    binary = bundledBinary() ?? undefined;
    if (!binary) {
      throw new Error(
        `no stream_doctor binary bundled for ${process.platform}-${process.arch}, pass one with \`binary\` or a running daemon with \`daemonUrl\``
      );
    }
    installDir = path.join(path.dirname(binary), "..", ".burrito");
  }
  port ??= await freePort();
  const url = `http://localhost:${port}`;
  const child = await spawnDaemon(binary, url, port, installDir);
  return new Session(url, child, LOG_FILE);
}

/** Path to the daemon binary bundled for this platform, or null if there is none. */
export function bundledBinary(): string | null {
  const pkg = PLATFORM_PACKAGES[`${process.platform}-${process.arch}`];
  if (!pkg) return null;
  try {
    return createRequire(import.meta.url).resolve(`${pkg}/bin/stream_doctor`);
  } catch {
    return null;
  }
}

/** A connection to the daemon, grouping one publisher and any number of viewers. */
class Session {
  daemonUrl: string;
  child: ChildProcess | null;
  logFile: string | null;

  constructor(daemonUrl: string, child: ChildProcess | null, logFile: string | null = null) {
    this.daemonUrl = daemonUrl;
    this.child = child;
    this.logFile = logFile;
  }

  /** Starts publishing `file` to `rtmpUrl`. */
  publish(rtmpUrl: string, { file = "test.mp4" }: { file?: string } = {}): Streamer {
    const ready = api<StreamerStatus>(
      "POST",
      "/streamer",
      { input: file, rtmp_url: rtmpUrl },
      this.daemonUrl
    );
    return new Streamer(this.daemonUrl, ready);
  }

  /** Starts a viewer collecting metrics from the HLS playlist at `hlsUrl`. */
  async watch(hlsUrl: string): Promise<Viewer> {
    const { id } = await api<ViewerStatus>("POST", "/viewers", { hls_url: hlsUrl }, this.daemonUrl);
    return new Viewer(this.daemonUrl, id);
  }

  /** Current state of the daemon. */
  status(): Promise<DaemonStatus> {
    return api("GET", "/status", null, this.daemonUrl);
  }

  /** Stops the daemon if this session spawned it. */
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

/** The publisher of a session. */
class Streamer {
  daemonUrl: string;
  ready: Promise<StreamerStatus>;

  constructor(daemonUrl: string, ready: Promise<StreamerStatus>) {
    this.daemonUrl = daemonUrl;
    this.ready = ready;
    ready.catch(() => {});
  }

  /** Current state of the publisher. */
  status(): Promise<StreamerStatus> {
    return this.ready.then(() => api("GET", "/streamer", null, this.daemonUrl));
  }

  /** Resolves once the stream is live, rejects if it ends or fails first. */
  async waitUntilLive({
    timeoutMs = 60_000,
    intervalMs = 250,
  }: { timeoutMs?: number; intervalMs?: number } = {}): Promise<StreamerStatus> {
    await this.ready;
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const streamer = await api<StreamerStatus>("GET", "/streamer", null, this.daemonUrl);
      if (streamer.live) return streamer;
      if (TERMINAL_STATUSES.includes(streamer.status)) {
        throw new Error(
          `streamer ${streamer.status} before going live${streamer.error ? `: ${streamer.error}` : ""}`
        );
      }
      if (Date.now() > deadline) throw new Error(`streamer not live within ${timeoutMs} ms`);
      await sleep(intervalMs);
    }
  }

  /** Stops publishing. */
  async stop(): Promise<StreamerStatus> {
    await this.ready;
    return api("DELETE", "/streamer", null, this.daemonUrl);
  }
}

/** A viewer of a session. */
class Viewer {
  daemonUrl: string;
  id: string;

  constructor(daemonUrl: string, id: string) {
    this.daemonUrl = daemonUrl;
    this.id = id;
  }

  /** Current state of the viewer. */
  status(): Promise<ViewerStatus> {
    return api("GET", `/viewers/${this.id}`, null, this.daemonUrl);
  }

  /** Metrics collected so far. */
  async metrics(): Promise<Metrics> {
    const { metrics } = await this.status();
    return metrics;
  }

  /** Resolves once the viewer ends, fails or is stopped, calling `onUpdate` with each polled state. */
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

  /** Stops the viewer and returns its final metrics. */
  async stop(): Promise<Metrics> {
    const { metrics } = await api<ViewerStatus>(
      "DELETE",
      `/viewers/${this.id}`,
      null,
      this.daemonUrl
    );
    return metrics;
  }
}

export type { Session, Streamer, Viewer };

async function spawnDaemon(
  binary: string,
  daemonUrl: string,
  port: number,
  installDir?: string
): Promise<ChildProcess> {
  if (!fs.existsSync(binary)) {
    throw new Error(`${binary} not found, build it with: MIX_ENV=prod mix release`);
  }
  const env = {
    ...process.env,
    STREAM_DOCTOR_EXIT_ON_STDIN_EOF: "1",
    PORT: String(port),
    ...(installDir ? { STREAM_DOCTOR_INSTALL_DIR: installDir } : {}),
  };
  const log = fs.openSync(LOG_FILE, "a");
  const child = spawn(binary, [], { stdio: ["pipe", log, log], detached: true, env });
  child.on("exit", () => fs.closeSync(log));
  for (const deadline = Date.now() + 120_000; Date.now() < deadline;) {
    if (child.exitCode !== null) {
      throw new Error(`daemon exited with ${child.exitCode}, see ${LOG_FILE}`);
    }
    await sleep(1000);
    try {
      await api("GET", "/status", null, daemonUrl);
      return child;
    } catch {}
  }
  throw new Error(`daemon didn't come up in 2 minutes, see ${LOG_FILE}`);
}

async function api<T>(
  method: string,
  path: string,
  body: object | null,
  daemonUrl: string
): Promise<T> {
  let res: Response;
  try {
    res = await fetch(daemonUrl + path, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (e) {
    throw new Error(
      `${method} ${path}: cannot reach ${daemonUrl} (is the daemon running?): ${(e as Error).message}`
    );
  }
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}: ${text}`);
  return JSON.parse(text);
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, () => {
      const { port } = probe.address() as AddressInfo;
      probe.close(() => resolve(port));
    });
  });
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
