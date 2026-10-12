import assert from "node:assert/strict";
import test from "node:test";
import { isRemoteHaUrl, recommendSettings } from "./recommendations.js";

const rec = (facts: Parameters<typeof recommendSettings>[0]) =>
  Object.fromEntries(recommendSettings(facts).map((r) => [r.key, r.value])) as Record<string, unknown>;

test("a small local setup gets the defaults", () => {
  const r = rec({ readableEntities: 12, activeKeys: 2, haRemote: false });
  assert.equal(r.stateSource, "subscription");
  assert.equal(r.cacheMs, 2000);
  assert.equal(r.maxConcurrency, 8);
  assert.equal(r.onLinkDown, "live-then-last-known");
  assert.equal(r.rateLimitPerMinute, 100);
  assert.equal(r.alertDownAfterSeconds, 120);
  assert.equal(r.alertReminderMinutes, 360);
});

test("no readable entities yet keeps the live subscription", () => {
  assert.equal(rec({ readableEntities: 0, activeKeys: 0, haRemote: false }).stateSource, "subscription");
});

test("exactly at the limit still uses the live subscription, above it does not", () => {
  assert.equal(rec({ readableEntities: 2000, activeKeys: 3, haRemote: false }).stateSource, "subscription");
  const big = rec({ readableEntities: 2001, activeKeys: 3, haRemote: false });
  assert.equal(big.stateSource, "cache");
  assert.equal(big.cacheMs, 5000);
  assert.equal(big.maxConcurrency, 4);
});

test("many keys without subscription widen the sharing window", () => {
  assert.equal(rec({ readableEntities: 2500, activeKeys: 1, haRemote: false }).cacheMs, 5000);
});

test("a remote Home Assistant lowers the ceiling and delays the first alert", () => {
  const r = rec({ readableEntities: 30, activeKeys: 2, haRemote: true });
  assert.equal(r.maxConcurrency, 4);
  assert.equal(r.alertDownAfterSeconds, 180);
});

test("every recommendation explains itself and stays inside the allowed ranges", () => {
  for (const facts of [
    { readableEntities: 0, activeKeys: 0, haRemote: false },
    { readableEntities: 500, activeKeys: 20, haRemote: true },
    { readableEntities: 5000, activeKeys: 20, haRemote: false }
  ]) {
    for (const item of recommendSettings(facts)) {
      assert.ok(item.reason.length > 20, `${String(item.key)} has a reason`);
    }
    const r = rec(facts);
    assert.ok((r.cacheMs as number) <= 60000 && (r.maxConcurrency as number) >= 1 && (r.maxConcurrency as number) <= 64);
    assert.ok((r.alertDownAfterSeconds as number) >= 30 && (r.alertDownAfterSeconds as number) <= 3600);
  }
});

test("local and remote Home Assistant addresses are told apart", () => {
  for (const u of ["http://homeassistant.local:8123", "http://192.168.1.20:8123", "http://10.0.0.5:8123", "http://172.20.0.1:8123", "http://127.0.0.1:8123", "http://host.docker.internal:8123", "http://homeassistant:8123", "http://localhost:8123"]) {
    assert.equal(isRemoteHaUrl(u), false, u);
  }
  for (const u of ["https://abc123.ui.nabu.casa", "https://ha.example.com", "http://8.8.8.8:8123", "http://172.32.0.1:8123"]) {
    assert.equal(isRemoteHaUrl(u), true, u);
  }
  assert.equal(isRemoteHaUrl("not a url"), false);
});
