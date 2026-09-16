import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http, { type IncomingMessage } from "node:http";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";

import { session } from "./stream_doctor.ts";

// A stand-in for the Elixir server: the streamer goes live on the third poll.
let streamerPolls = 0;
const viewers = new Map<string, object>();
let requests: { method?: string; path?: string; body: unknown }[] = [];

const routes: Record<string, (body: any) => object> = {
  "GET /status": () => ({ streamer: null, viewers: [] }),
  "POST /streamer": () => {
    streamerPolls = 0;
    return { status: "starting" };
  },
  "GET /streamer": () => ({
    status: streamerPolls++ >= 2 ? "running" : "starting",
    live: streamerPolls > 2,
  }),
  "DELETE /streamer": () => ({ status: "stopped" }),
  "POST /viewers": ({ hls_url }) => {
    const id = `v${viewers.size + 1}`;
    viewers.set(id, { id, hls_url, status: "ended", metrics: { av_drift: { drift_ms: 12 } } });
    return { id };
  },
};

const server = http.createServer((req, res) => {
  let body = "";
  const { method, url } = req as IncomingMessage & { url: string };
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    const json = body ? JSON.parse(body) : null;
    requests.push({ method, path: url, body: json });
    const viewer = url.match(/^\/viewers\/(\w+)$/);
    let payload: object | undefined;
    if (viewer && method === "GET") payload = viewers.get(viewer[1]);
    else if (viewer && method === "DELETE") {
      payload = viewers.get(viewer[1]);
      viewers.delete(viewer[1]);
    } else payload = routes[`${method} ${url}`]?.(json);
    if (!payload) {
      res.writeHead(404).end("no such route");
      return;
    }
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(payload));
  });
});

let url: string;
before(async () => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => {
  server.closeAllConnections();
  server.close();
});

test("session connects to a running server without spawning anything", async () => {
  const s = await session({ server: url });
  assert.equal(s.child, null);
  assert.deepEqual(await s.status(), { streamer: null, viewers: [] });
  await s.close();
});

test("session fails fast when nothing listens at the given server", async () => {
  await assert.rejects(session({ server: "http://127.0.0.1:1" }), /cannot reach/);
});

test("session refuses to combine server with binary or port", async () => {
  await assert.rejects(session({ server: url, binary: "/x" }), /cannot be combined/);
  await assert.rejects(session({ server: url, port: 1 }), /cannot be combined/);
});

test("session refuses to spawn a binary that does not exist", async () => {
  await assert.rejects(
    session({ binary: "/nonexistent/stream_doctor" }),
    /not found, build it with/
  );
});

test("session spawns the binary on the requested port and stops it on close", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stream_doctor_test_"));
  const fake = path.join(dir, "fake_daemon");
  fs.writeFileSync(
    fake,
    `#!/bin/sh\nexec ${process.execPath} -e 'require("node:http").createServer((_, res) => res.end("{\\"streamer\\":null,\\"viewers\\":[]}")).listen(process.env.PORT)'\n`,
    { mode: 0o755 }
  );
  const port = 40_000 + Math.floor(Math.random() * 10_000);
  const s = await session({ binary: fake, port });
  assert.equal(s.server, `http://localhost:${port}`);
  assert.deepEqual(await s.status(), { streamer: null, viewers: [] });
  await s.close();
  await assert.rejects(s.status(), /cannot reach/);
});

test("publish posts the input and waitUntilLive polls until frames flow", async () => {
  requests = [];
  const s = await session({ server: url });
  const streamer = s.publish("rtmp://host/app/key", { file: "clip.mp4" });
  const live = await streamer.waitUntilLive({ intervalMs: 1 });
  assert.equal(live.live, true);
  assert.deepEqual(requests[1], {
    method: "POST",
    path: "/streamer",
    body: { input: "clip.mp4", rtmp_url: "rtmp://host/app/key" },
  });
  assert.equal(requests.filter((r) => r.method === "GET" && r.path === "/streamer").length, 3);
  assert.deepEqual(await streamer.stop(), { status: "stopped" });
});

test("waitUntilLive reports a streamer that failed before going live", async () => {
  const s = await session({ server: url });
  routes["GET /streamer"] = () => ({ status: "failed", live: false, error: "boom" });
  const streamer = s.publish("rtmp://host/app/key");
  await assert.rejects(streamer.waitUntilLive({ intervalMs: 1 }), /streamer failed.*: boom/);
});

test("watch creates a viewer whose metrics and stop go through the API", async () => {
  const s = await session({ server: url });
  const viewer = await s.watch("http://cdn/index.m3u8");
  assert.equal(viewer.id, "v1");
  assert.deepEqual(await viewer.metrics(), { av_drift: { drift_ms: 12 } } as object);
  const done = await viewer.waitUntilDone({ intervalMs: 1 });
  assert.equal(done.hls_url, "http://cdn/index.m3u8");
  assert.deepEqual(await viewer.stop(), { av_drift: { drift_ms: 12 } });
  await assert.rejects(viewer.status(), /HTTP 404/);
});
