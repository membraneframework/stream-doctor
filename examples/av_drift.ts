import { session, type Streamer, type Viewer } from "stream-doctor";

const RTMP_URL = "rtmp://127.0.0.1:1935/live/test";
const HLS_URL = "http://127.0.0.1:8123/index.m3u8";
const MAX_DRIFT_MS = 50;
const SAMPLES = 40;
const SAMPLE_INTERVAL_MS = 1000;

const file = process.argv[2] ?? "test.mp4";

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

console.log("Starting the Stream Doctor daemon...");
const doctor = await session();

let streamer: Streamer | undefined;
let viewer: Viewer | undefined;

try {
  console.log(`Publishing ${file} to ${RTMP_URL}...`);
  streamer = doctor.publish(RTMP_URL, { file });
  await streamer.waitUntilLive();
  console.log("Stream is live.");

  console.log(`Watching ${HLS_URL}...`);
  viewer = await doctor.watch(HLS_URL);

  let drift = null;
  for (let i = 0; i < SAMPLES; i++) {
    await sleep(SAMPLE_INTERVAL_MS);
    drift = (await viewer.metrics()).av_drift?.drift_ms ?? null;
    console.log(
      drift === null ? "A/V drift: not measured yet" : `A/V drift: ${drift} ms`,
    );
  }

  const pass = drift !== null && Math.abs(drift) < MAX_DRIFT_MS;
  console.log(
    pass
      ? `PASS: A/V drift is below ${MAX_DRIFT_MS} ms`
      : `FAIL: A/V drift is above ${MAX_DRIFT_MS} ms`,
  );
  process.exitCode = pass ? 0 : 1;
} finally {
  await viewer?.stop();
  await streamer?.stop();
  await doctor.close();
}
