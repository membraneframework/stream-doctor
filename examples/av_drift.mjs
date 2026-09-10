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

const session = await stream_doc.session({ binary: BINARY, cwd: REPO_ROOT });
process.on("SIGINT", () => session.close().then(() => process.exit(130)));

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
  await session.close();
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) out[argv[i].replace(/^--/, "")] = argv[i + 1];
  return out;
}
