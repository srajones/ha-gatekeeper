import assert from "node:assert/strict";
import test from "node:test";
import { CoalescingCache, ConcurrencyLimiter, HaBusyError } from "./haGateway.js";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

test("limiter never runs more than maxConcurrent tasks at once and runs the rest in order", async () => {
  const limiter = new ConcurrencyLimiter(3, 100, 5000);
  let running = 0;
  let peak = 0;
  const order: number[] = [];

  await Promise.all(
    Array.from({ length: 20 }, (_, i) =>
      limiter.run(async () => {
        running += 1;
        peak = Math.max(peak, running);
        order.push(i);
        await sleep(5);
        running -= 1;
      })
    )
  );

  assert.equal(peak, 3);
  assert.deepEqual(order, Array.from({ length: 20 }, (_, i) => i));
  assert.equal(limiter.inFlight, 0);
  assert.equal(limiter.waiting, 0);
});

test("limiter says ha_busy when the queue is full", async () => {
  const limiter = new ConcurrencyLimiter(1, 2, 5000);
  const gate = deferred<void>();
  const first = limiter.run(() => gate.promise);
  const queued = [limiter.run(async () => 1), limiter.run(async () => 2)];

  await assert.rejects(() => limiter.run(async () => 3), HaBusyError);

  gate.resolve();
  await first;
  assert.deepEqual(await Promise.all(queued), [1, 2]);
  assert.equal(limiter.inFlight, 0);
});

test("limiter says ha_busy when a request waits too long, and keeps working afterwards", async () => {
  const limiter = new ConcurrencyLimiter(1, 10, 30);
  const gate = deferred<void>();
  const first = limiter.run(() => gate.promise);

  await assert.rejects(() => limiter.run(async () => 1), HaBusyError);
  assert.equal(limiter.waiting, 0);

  gate.resolve();
  await first;
  assert.equal(await limiter.run(async () => "ok"), "ok");
});

test("limiter releases its slot when a task throws", async () => {
  const limiter = new ConcurrencyLimiter(1, 5, 1000);
  await assert.rejects(() => limiter.run(async () => Promise.reject(new Error("boom"))), /boom/);
  assert.equal(await limiter.run(async () => "after"), "after");
  assert.equal(limiter.inFlight, 0);
});

test("simultaneous reads of one key share a single load", async () => {
  const cache = new CoalescingCache<string>(1000);
  let loads = 0;
  const gate = deferred<string>();
  const load = () => {
    loads += 1;
    return gate.promise;
  };

  const reads = Array.from({ length: 100 }, () => cache.get("light.a", load, () => true));
  gate.resolve("on");

  assert.deepEqual(new Set(await Promise.all(reads)), new Set(["on"]));
  assert.equal(loads, 1);
});

test("a cached value is served until it expires, then loaded again", async () => {
  let clock = 1000;
  const cache = new CoalescingCache<number>(2000, () => clock);
  let loads = 0;
  const load = async () => ++loads;

  assert.equal(await cache.get("k", load, () => true), 1);
  clock += 1999;
  assert.equal(await cache.get("k", load, () => true), 1);
  clock += 2;
  assert.equal(await cache.get("k", load, () => true), 2);
  assert.equal(loads, 2);
});

test("different keys are loaded separately", async () => {
  const cache = new CoalescingCache<string>(1000);
  let loads = 0;
  const results = await Promise.all(
    ["a", "b", "c", "a", "b"].map((key) =>
      cache.get(key, async () => {
        loads += 1;
        return key;
      }, () => true)
    )
  );
  assert.deepEqual(results, ["a", "b", "c", "a", "b"]);
  assert.equal(loads, 3);
});

test("values that are not cacheable and failures are not kept", async () => {
  const cache = new CoalescingCache<{ ok: boolean }>(1000);
  let loads = 0;
  const bad = async () => ({ ok: (loads += 1) < 0 });

  await cache.get("k", bad, (v) => v.ok);
  await cache.get("k", bad, (v) => v.ok);
  assert.equal(loads, 2);

  let attempts = 0;
  const flaky = async () => {
    attempts += 1;
    if (attempts === 1) {
      throw new Error("down");
    }
    return { ok: true };
  };
  await assert.rejects(() => cache.get("f", flaky, (v) => v.ok), /down/);
  assert.deepEqual(await cache.get("f", flaky, (v) => v.ok), { ok: true });
});

test("invalidate drops cached values and a read that started before it is not stored", async () => {
  const cache = new CoalescingCache<string>(60_000);
  let version = "old";
  const gate = deferred<void>();
  const slow = async () => {
    const seen = version;
    await gate.promise;
    return seen;
  };

  const inFlight = cache.get("k", slow, () => true);
  version = "new";
  cache.invalidate();
  gate.resolve();

  assert.equal(await inFlight, "old"); // the caller that was already waiting still gets its answer
  assert.equal(cache.size, 0); // but it was not kept
  assert.equal(await cache.get("k", async () => version, () => true), "new");
});

test("ttl 0 disables caching but still merges simultaneous reads", async () => {
  const cache = new CoalescingCache<number>(0);
  let loads = 0;
  const gate = deferred<void>();
  const load = async () => {
    loads += 1;
    await gate.promise;
    return loads;
  };
  const reads = [cache.get("k", load, () => true), cache.get("k", load, () => true)];
  gate.resolve();
  await Promise.all(reads);
  assert.equal(loads, 1);
  await cache.get("k", async () => 99, () => true);
  assert.equal(cache.size, 0);
});

test("the cache never grows past maxEntries", async () => {
  const cache = new CoalescingCache<number>(60_000, Date.now, 3);
  for (let i = 0; i < 10; i += 1) {
    await cache.get(`k${i}`, async () => i, () => true);
  }
  assert.equal(cache.size, 3);
});
