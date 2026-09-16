import * as stream_doc from "stream-doctor";

const file = process.argv[2] ?? "test.mp4";
const rtmpUrl = "rtmp://127.0.0.1:1935/live/test";
const hlsUrl = "http://127.0.0.1:8123/index.m3u8";

console.log("Starting the Stream Doctor daemon...");
const session = await stream_doc.session();

console.log(`Publishing ${file} to ${rtmpUrl}...`);
const streamer = session.publish(rtmpUrl, { file });
await streamer.waitUntilLive();
console.log("Stream is live.");

console.log(`Watching ${hlsUrl}...`);
const viewer = await session.watch(hlsUrl);

let drift: number | null = null;
for (let i = 0; i < 40; i++) {
  await new Promise((resolve) => setTimeout(resolve, 1000));
  drift = (await viewer.metrics()).av_drift?.drift_ms ?? null;
  console.log(
    drift == null ? "A/V drift: not measured yet" : `A/V drift: ${drift} ms`,
  );
}

const pass = drift != null && Math.abs(drift) < 50;
console.log(
  pass ? "PASS: A/V drift is below 50 ms" : "FAIL: A/V drift is above 50 ms",
);
process.exitCode = pass ? 0 : 1;

await viewer.stop();
await streamer.stop();
await session.close();
