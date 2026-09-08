// End-to-end A/V drift check against a local ffmpeg RTMP -> HLS repackager.
//
// Runs, in order:
//   1. `mix stream_doctor.server` (from the repo root) and a static HTTP server
//      for the HLS output,
//   2. scenario "passthrough": ffmpeg listens on RTMP and repackages to HLS with
//      `-c copy`; the streamer publishes test.mp4, a viewer measures
//      av_drift - expected ~0 ms,
//   3. scenario "audio delayed 200 ms": same, but with `-af adelay=200|200`
//      (audio re-encoded to AAC) - expected ~+200 ms (audio lags video).
//
// Usage (from the repo root, with ffmpeg and node on PATH):
//   node examples/av_drift.mjs [--file test.mp4] [--measure-s 30]
//
// Ports: 4040 (stream_doctor server), 1935 (ffmpeg RTMP listener),
// 8123 (HLS http server). Everything is torn down on exit / Ctrl-C.

import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as stream_doc from "../stream_doctor.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SERVER_PORT = 4040;
const RTMP_PORT = 1935;
const HLS_PORT = 8123;
const RTMP_URL = `rtmp://127.0.0.1:${RTMP_PORT}/live/test`;
const HLS_URL = `http://127.0.0.1:${HLS_PORT}/index.m3u8`;

const args = parseArgs(process.argv.slice(2));
const FILE = args.file ?? "test.mp4";
// how long to keep measuring after the first drift sample is available
const MEASURE_MS = Number(args["measure-s"] ?? 30) * 1000;

// ffmpeg output options per scenario (input options are shared, see runFfmpeg)
const SCENARIOS = [
  {
    name: "passthrough",
    expectedDriftMs: 0,
    ffmpegArgs: ["-c", "copy"],
  },
  {
    name: "audio delayed 200 ms (-af adelay=200|200)",
    expectedDriftMs: 200,
    // adelay shifts the audio content 200 ms later relative to its
    // timestamps; the filter forces an audio re-encode
    ffmpegArgs: ["-c:v", "copy", "-af", "adelay=200|200", "-c:a", "aac", "-b:a", "128k"],
  },
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const fmt = (v) => (v == null ? "n/a" : String(v));
const shellQuote = (s) => (/[\s|"']/.test(s) ? `'${s}'` : s);
const log = (tag, msg) => console.log(`[${tag}] ${msg}`);
const banner = (msg) => console.log(`\n=== ${msg} ===`);

const children = new Set();
let hlsServer;

process.on("SIGINT", () => cleanup().then(() => process.exit(130)));
process.on("SIGTERM", () => cleanup().then(() => process.exit(143)));

try {
  const results = await main();
  printSummary(results);
  await cleanup();
  process.exit(results.every((r) => r.ok) ? 0 : 1);
} catch (e) {
  console.error(`\nERROR: ${e.stack ?? e}`);
  await cleanup();
  process.exit(1);
}

async function main() {
  const hlsDir = fs.mkdtempSync(path.join(os.tmpdir(), "stream_doctor_hls_"));
  hlsServer = await serveDir(hlsDir, HLS_PORT);
  log("hls", `serving ${hlsDir} on ${HLS_URL}`);

  const session = await startStreamDoctorServer();

  const results = [];
  for (const scenario of SCENARIOS) {
    results.push(await runScenario(session, scenario, hlsDir));
  }
  return results;
}

async function runScenario(session, scenario, hlsDir) {
  banner(`scenario: ${scenario.name} (expected drift ~${scenario.expectedDriftMs} ms)`);

  // fresh playlist for every run: a leftover #EXT-X-ENDLIST would make the
  // server refuse the playlist as a finished VoD
  for (const f of fs.readdirSync(hlsDir)) fs.rmSync(path.join(hlsDir, f));

  const ffmpeg = runFfmpeg(scenario.ffmpegArgs, hlsDir);
  let streamer, viewer;
  try {
    // the RTMP listener must be up before the streamer connects
    await sleep(1000);
    if (ffmpeg.exitCode !== null) throw new Error(`ffmpeg exited early with ${ffmpeg.exitCode}`);

    streamer = session.publish(RTMP_URL, { file: FILE });
    await streamer.waitUntilLive();
    log("streamer", "live");

    viewer = await session.watch(HLS_URL);
    log("viewer", `${viewer.id} started, waiting for the first drift sample...`);

    await waitFor(
      async () => (await viewer.metrics())?.av_drift?.drift_ms != null,
      { timeoutMs: 120_000, what: "first av_drift sample", check: () => assertAlive(ffmpeg, streamer, viewer) }
    );

    log("viewer", `measuring for ${MEASURE_MS / 1000} s`);
    const deadline = Date.now() + MEASURE_MS;
    let metrics;
    while (Date.now() < deadline) {
      await sleep(2000);
      await assertAlive(ffmpeg, streamer, viewer);
      metrics = await viewer.metrics();
      log("viewer", `drift ${fmt(metrics.av_drift.drift_ms)} ms`);
    }

    const final = await viewer.stop();
    viewer = null;
    return summarize(scenario, final);
  } finally {
    if (viewer) await viewer.stop().catch(() => {});
    if (streamer) await streamer.stop().catch(() => {});
    await kill(ffmpeg);
  }
}

function summarize(scenario, metrics) {
  const drift = metrics.av_drift;
  const samples = drift.latest_samples ?? [];
  const median = samples.length ? [...samples].sort((a, b) => a - b)[samples.length >> 1] : null;
  const tolerance = 40;
  const ok = drift.drift_ms != null && Math.abs(drift.drift_ms - scenario.expectedDriftMs) <= tolerance;
  return {
    name: scenario.name,
    expected: scenario.expectedDriftMs,
    drift_ms: drift.drift_ms,
    median_recent_ms: median,
    tolerance,
    ok,
  };
}

function printSummary(results) {
  banner("summary");
  for (const r of results) {
    console.log(
      `${r.ok ? "PASS" : "FAIL"}  ${r.name}: drift ${fmt(r.drift_ms)} ms ` +
        `(expected ${r.expected} ±${r.tolerance}; median of recent ${fmt(r.median_recent_ms)} ms)`
    );
  }
}

// ---------------------------------------------------------------- processes

async function startStreamDoctorServer() {
  const server = `http://localhost:${SERVER_PORT}`;
  // reuse an already running server (e.g. started by hand for debugging)
  try {
    const session = await stream_doc.session({ server });
    log("server", `using already running server at ${server}`);
    return session;
  } catch {}

  log("server", "starting mix stream_doctor.server (first run compiles - may take a while)");
  const child = spawnLogged("server", "mix", ["stream_doctor.server", "--port", String(SERVER_PORT)], {
    cwd: REPO_ROOT,
  });

  await waitFor(
    async () => {
      if (child.exitCode !== null) throw new Error(`mix stream_doctor.server exited with ${child.exitCode}`);
      try {
        await stream_doc.session({ server });
        return true;
      } catch {
        return false;
      }
    },
    { timeoutMs: 300_000, intervalMs: 1000, what: "stream_doctor server" }
  );
  return stream_doc.session({ server });
}

function runFfmpeg(outputArgs, hlsDir) {
  const ffmpegArgs = [
    "-hide_banner", "-loglevel", "warning", "-y",
    "-listen", "1", "-f", "flv", "-i", RTMP_URL,
    ...outputArgs,
    "-f", "hls", "-hls_time", "2", "-hls_list_size", "0",
    path.join(hlsDir, "index.m3u8"),
  ];
  log("ffmpeg", `ffmpeg ${ffmpegArgs.map(shellQuote).join(" ")}`);
  return spawnLogged("ffmpeg", "ffmpeg", ffmpegArgs);
}

function spawnLogged(tag, cmd, cmdArgs, opts = {}) {
  const child = spawn(cmd, cmdArgs, { stdio: ["ignore", "pipe", "pipe"], ...opts });
  children.add(child);
  child.on("exit", () => children.delete(child));
  child.on("error", (e) => log(tag, `failed to start ${cmd}: ${e.message}`));
  for (const stream of [child.stdout, child.stderr]) {
    let buf = "";
    stream.on("data", (chunk) => {
      buf += chunk;
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const line of lines) if (line.trim()) log(tag, line);
    });
  }
  return child;
}

async function assertAlive(ffmpeg, streamer, viewer) {
  if (ffmpeg.exitCode !== null) throw new Error(`ffmpeg exited with ${ffmpeg.exitCode}`);
  const s = await streamer.status();
  if (["ended", "failed", "stopped"].includes(s.status)) {
    throw new Error(`streamer ${s.status}${s.error ? `: ${s.error}` : ""}`);
  }
  const v = await viewer.status();
  if (["ended", "failed", "stopped"].includes(v.status)) {
    throw new Error(`viewer ${v.status}${v.error ? `: ${v.error}` : ""}`);
  }
}

function kill(child) {
  if (!child || child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    child.kill("SIGTERM");
  });
}

async function cleanup() {
  await Promise.all([...children].map(kill));
  if (hlsServer) await new Promise((resolve) => hlsServer.close(resolve));
}

// ------------------------------------------------------------------ helpers

function serveDir(dir, port) {
  const types = { ".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".m4s": "video/iso.segment", ".mp4": "video/mp4" };
  const server = http.createServer((req, res) => {
    const file = path.join(dir, path.normalize(decodeURIComponent(req.url.split("?")[0])));
    if (!file.startsWith(dir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, {
      "content-type": types[path.extname(file)] ?? "application/octet-stream",
      "cache-control": "no-store",
    });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server));
  });
}

async function waitFor(predicate, { timeoutMs, intervalMs = 1000, what, check }) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (check) await check();
    if (await predicate()) return;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what} (${timeoutMs / 1000} s)`);
    await sleep(intervalMs);
  }
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) out[argv[i].slice(2)] = argv[i + 1] ?? true, i++;
  }
  return out;
}
