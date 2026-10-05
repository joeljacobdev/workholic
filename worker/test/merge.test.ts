import assert from "node:assert/strict";
import test from "node:test";
import { creditDay, type RawInterval } from "../src/merge.ts";

const dayStart = 0;
const dayEnd = 1_000;

function row(partial: Partial<RawInterval> & Pick<RawInterval, "deviceId" | "startMs" | "endMs">): RawInterval {
  return {
    appKey: "com.example.App",
    inputMs: partial.startMs,
    ...partial,
  };
}

test("one device sums abutting slices once", () => {
  const credit = creditDay(
    [row({ deviceId: "a", startMs: 0, endMs: 100, inputMs: 90 }), row({ deviceId: "a", startMs: 100, endMs: 250, inputMs: 200 })],
    dayStart,
    dayEnd,
  );
  assert.equal(credit.creditedMs, 250);
  assert.equal(credit.devices[0]?.rawMs, 250);
  assert.equal(credit.devices[0]?.creditedMs, 250);
});

test("the same device overlapping itself is not counted twice", () => {
  const credit = creditDay(
    [row({ deviceId: "a", startMs: 0, endMs: 100, inputMs: 80 }), row({ deviceId: "a", startMs: 50, endMs: 120, inputMs: 110 })],
    dayStart,
    dayEnd,
  );
  assert.equal(credit.creditedMs, 120);
  assert.equal(credit.devices[0]?.rawMs, 120);
});

test("later real input wins an overlap", () => {
  const credit = creditDay(
    [
      row({ deviceId: "laptop", appKey: "com.apple.Terminal", startMs: 0, endMs: 100, inputMs: 10 }),
      row({ deviceId: "phone", appKey: "notes", startMs: 50, endMs: 150, inputMs: 80 }),
    ],
    dayStart,
    dayEnd,
  );
  assert.equal(credit.creditedMs, 150);
  const laptop = credit.devices.find((device) => device.deviceId === "laptop");
  const phone = credit.devices.find((device) => device.deviceId === "phone");
  assert.equal(laptop?.creditedMs, 50);
  assert.equal(phone?.creditedMs, 100);
  assert.equal(laptop?.rawMs, 100);
  assert.equal(phone?.rawMs, 100);
});

test("a tie inside the same input time goes to the larger device id", () => {
  const credit = creditDay(
    [
      row({ deviceId: "aaa", startMs: 0, endMs: 100, inputMs: 40 }),
      row({ deviceId: "bbb", startMs: 0, endMs: 100, inputMs: 40 }),
    ],
    dayStart,
    dayEnd,
  );
  assert.equal(credit.creditedMs, 100);
  assert.equal(credit.devices.find((device) => device.deviceId === "bbb")?.creditedMs, 100);
  assert.equal(credit.devices.find((device) => device.deviceId === "aaa")?.creditedMs, 0);
});

test("time outside the day is clipped", () => {
  const credit = creditDay([row({ deviceId: "a", startMs: -50, endMs: 40, inputMs: 30 })], 0, 100);
  assert.equal(credit.creditedMs, 40);
});

test("unattributed time still counts toward the ceiling", () => {
  const credit = creditDay([row({ deviceId: "a", appKey: "unattributed", startMs: 0, endMs: 30, inputMs: 20 })], 0, 100);
  assert.equal(credit.creditedMs, 30);
  assert.equal(credit.unattributedMs, 30);
});

test("credited time is split per device app and laid out as a timeline", () => {
  const credit = creditDay(
    [
      row({ deviceId: "laptop", appKey: "com.apple.Terminal", startMs: 0, endMs: 100, inputMs: 10 }),
      row({ deviceId: "laptop", appKey: "com.apple.Terminal", startMs: 100, endMs: 200, inputMs: 150 }),
      row({ deviceId: "desk", appKey: "com.apple.Safari", startMs: 50, endMs: 120, inputMs: 60 }),
      row({ deviceId: "desk", appKey: "com.apple.Safari", startMs: 300, endMs: 400, inputMs: 300 }),
    ],
    dayStart,
    dayEnd,
  );
  assert.deepEqual(credit.segments, [
    { deviceId: "laptop", appKey: "com.apple.Terminal", startMs: 0, endMs: 50 },
    { deviceId: "desk", appKey: "com.apple.Safari", startMs: 50, endMs: 100 },
    { deviceId: "laptop", appKey: "com.apple.Terminal", startMs: 100, endMs: 200 },
    { deviceId: "desk", appKey: "com.apple.Safari", startMs: 300, endMs: 400 },
  ]);
  assert.deepEqual(credit.deviceApps, [
    { deviceId: "desk", appKey: "com.apple.Safari", creditedMs: 150 },
    { deviceId: "laptop", appKey: "com.apple.Terminal", creditedMs: 150 },
  ]);
});
