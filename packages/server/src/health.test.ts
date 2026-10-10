import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseHealth } from "./health.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("healthy while both probes work", async () => {
  const h = new DatabaseHealth({ read: async () => 1, write: async () => 1 });
  assert.deepEqual(await h.quick(), { ok: true });
  assert.deepEqual(await h.full(), { ok: true });
  assert.equal(h.consecutiveFailures, 0);
});

test("a failing read is reported at once", async () => {
  let fail = false;
  const h = new DatabaseHealth({ read: async () => { if (fail) throw new Error("SQLITE_IOERR"); }, write: async () => 1 });
  assert.equal((await h.quick()).ok, true);
  fail = true;
  const r = await h.quick();
  assert.equal(r.ok, false);
  assert.match(r.error!, /SQLITE_IOERR/);
});

test("a failing write (disk full, read-only) is remembered, so /healthz turns bad until a write works again", async () => {
  let fail = false;
  const h = new DatabaseHealth({ read: async () => 1, write: async () => { if (fail) throw new Error("SQLITE_FULL: database or disk is full"); } });
  await h.full();
  fail = true;
  assert.equal((await h.full()).ok, false);
  assert.equal((await h.quick()).ok, false, "quick() reports the last failed write");
  assert.match((await h.quick()).error!, /SQLITE_FULL/);
  fail = false;
  assert.equal((await h.full()).ok, true);
  assert.equal((await h.quick()).ok, true);
  assert.equal(h.consecutiveFailures, 0);
});

test("consecutive failures are counted and reset by one success", async () => {
  let fail = true;
  const h = new DatabaseHealth({ read: async () => { if (fail) throw new Error("x"); }, write: async () => 1 });
  await h.full(); await h.full(); await h.full();
  assert.equal(h.consecutiveFailures, 3);
  fail = false;
  await h.full();
  assert.equal(h.consecutiveFailures, 0);
});

test("a database that hangs is a failure after the timeout, not a hang of the health check", async () => {
  const h = new DatabaseHealth({ read: () => new Promise(() => undefined), write: async () => 1, timeoutMs: 80 });
  const started = Date.now();
  const r = await h.quick();
  assert.equal(r.ok, false);
  assert.match(r.error!, /timed out/);
  assert.ok(Date.now() - started < 1000);
  await sleep(1);
});

test("a throwing (not rejecting) probe is also handled", async () => {
  const h = new DatabaseHealth({ read: () => { throw new Error("sync boom"); }, write: async () => 1 });
  assert.equal((await h.quick()).ok, false);
});
