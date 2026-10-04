import assert from "node:assert/strict";
import test from "node:test";
import { dayKey, dayWindow, startOfZonedDay } from "../src/day.ts";

test("Los Angeles midnight is 07:00 UTC in October", () => {
  const start = startOfZonedDay("2026-10-04", "America/Los_Angeles");
  assert.equal(new Date(start).toISOString(), "2026-10-04T07:00:00.000Z");
  assert.equal(dayKey(start, "America/Los_Angeles"), "2026-10-04");
  assert.equal(dayKey(start - 1, "America/Los_Angeles"), "2026-10-03");
});

test("day window ends at the next local midnight", () => {
  const window = dayWindow("2026-10-04", "America/Los_Angeles");
  assert.equal(window.endMs - window.startMs, 24 * 60 * 60 * 1000);
  assert.equal(dayKey(window.endMs, "America/Los_Angeles"), "2026-10-05");
});

test("spring-forward day is 23 hours", () => {
  const window = dayWindow("2026-03-08", "America/Los_Angeles");
  assert.equal(window.endMs - window.startMs, 23 * 60 * 60 * 1000);
});

test("fall-back day is 25 hours", () => {
  const window = dayWindow("2026-11-01", "America/Los_Angeles");
  assert.equal(window.endMs - window.startMs, 25 * 60 * 60 * 1000);
});
