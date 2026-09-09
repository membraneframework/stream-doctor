// Asserts the A/V drift of a stream through whatever infra is running.
//
//   MIX_ENV=prod mix release            # once, builds the binary
//   examples/working_infra.sh           # terminal 1 (or buggy_infra.sh)
//   node examples/av_drift.mjs          # terminal 2, expect PASS / FAIL
//
// Spawns the burrito binary unless a server is already listening on :4040.
// Options: --file test.mp4 --measure-s 30 --expect 0 --tolerance 40
//          --binary burrito_out/stream_doctor_macos_arm

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as stream_doc from "../js/stream_doctor.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const args = parseArgs(process.argv.slice(2));
const FILE = args.file ?? "test.mp4";
const MEASURE_MS = Number(args["measure-s"] ?? 30) * 1000;
const EXPECT = Number(args.expect ?? 0);
const TOLERANCE = Number(args.tolerance ?? 40);
const BINARY = path.resolve(REPO_ROOT, args.binary ?? "burrito_out/stream_doctor_macos_arm");
const RTMP_URL = "rtmp://127.0.0.1:1935/live/test";
const HLS_URL = "http://127.0.0.1:8123/index.m3u8";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const dead = (s) => ["ended", "failed", "stopped"].includes(s.status);

const { session, server } = await connectOrSpawnServer();
process.on("SIGINT", () => stopServer().then(() => process.exit(130)));
const streamer = session.publish(RTMP_URL, { file: FILE });
let viewer;
try {
  await streamer.waitUntilLive();
  viewer = await session.watch(HLS_URL);
  console.log(`streamer live, ${viewer.id} watching ${HLS_URL}`);

  let drift = null;
  let stopAt = Date.now() + 120_000;
  while (Date.now() < stopAt) {
    await sleep(2000);
    for (const s of [await streamer.status(), await viewer.status()]) {
      if (dead(s)) throw new Error(`${s.status}${s.error ? `: ${s.error}` : ""}`);
    }
    const m = (await viewer.metrics()).av_drift;
    if (m.drift_ms == null) continue;
    if (drift == null) {
      stopAt = Date.now() + MEASURE_MS;
      console.log(`first sample, measuring for ${MEASURE_MS / 1000} s`);
    }
    drift = m.drift_ms;
    console.log(`drift ${drift} ms`);
  }
  if (drift == null) throw new Error("no drift sample within 2 minutes");

  const ok = Math.abs(drift - EXPECT) <= TOLERANCE;
  console.log(`${ok ? "PASS" : "FAIL"}: drift ${drift} ms, expected ${EXPECT} ±${TOLERANCE}`);
  process.exitCode = ok ? 0 : 1;
} finally {
  if (viewer) await viewer.stop().catch(() => {});
  await streamer.stop().catch(() => {});
  await stopServer();
}

async function connectOrSpawnServer() {
  try {
    return { session: await stream_doc.session(), server: null };
  } catch {}
  if (!fs.existsSync(BINARY)) {
    throw new Error(`${BINARY} not found, build it with: MIX_ENV=prod mix release`);
  }
  console.log(`starting ${path.relative(REPO_ROOT, BINARY)} (first run unpacks, be patient)`);
  // own process group: the burrito launcher doesn't take the BEAM down with it
  const server = spawn(BINARY, [], { cwd: REPO_ROOT, stdio: ["ignore", "inherit", "inherit"], detached: true });
  for (const deadline = Date.now() + 120_000; Date.now() < deadline; ) {
    if (server.exitCode !== null) throw new Error(`server exited with ${server.exitCode}`);
    await sleep(1000);
    try {
      return { session: await stream_doc.session(), server };
    } catch {}
  }
  throw new Error("server didn't come up in 2 minutes");
}

function stopServer() {
  if (!server || server.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    setTimeout(() => process.kill(-server.pid, "SIGKILL"), 5000).unref();
    server.once("exit", resolve);
    process.kill(-server.pid, "SIGTERM");
  });
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) out[argv[i].replace(/^--/, "")] = argv[i + 1];
  return out;
}
