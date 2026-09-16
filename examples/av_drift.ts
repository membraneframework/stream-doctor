import * as stream_doc from "../sdks/ts/src/stream_doctor.ts";

const file = process.argv[2] ?? "test.mp4";

const session = await stream_doc.session();
const streamer = session.publish("rtmp://127.0.0.1:1935/live/test", { file });
await streamer.waitUntilLive();
const viewer = await session.watch("http://127.0.0.1:8123/index.m3u8");

let drift: number | null = null;
for (let i = 0; i < 40; i++) {
  await new Promise((resolve) => setTimeout(resolve, 1000));
  drift = (await viewer.metrics()).av_drift?.drift_ms ?? null;
  console.log(`drift ${drift} ms`);
}

const pass = drift != null && Math.abs(drift) < 50;
console.log(pass ? "PASS" : "FAIL");
process.exitCode = pass ? 0 : 1;

await viewer.stop();
await streamer.stop();
await session.close();
