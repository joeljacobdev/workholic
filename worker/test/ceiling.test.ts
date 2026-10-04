import assert from "node:assert/strict";
import test from "node:test";
import { limitCutoff, standingLimit, type LimitVersion } from "../src/ceiling.ts";

const hour = 60 * 60 * 1000;
const day = 24 * hour;
// America/Los_Angeles midnight on 2026-10-04.
const todayStart = Date.parse("2026-10-04T07:00:00.000Z");
const todayNoon = todayStart + 12 * hour;
const todayEnd = todayStart + day;
const tomorrowNoon = todayEnd + 12 * hour;

test("a change today replaces today, and tomorrow's change leaves today alone", () => {
  const versions: LimitVersion[] = [];
  assert.equal(standingLimit(versions, todayNoon), null);

  versions.push({ limitMs: 6 * hour, effectiveAtMs: todayStart + hour });
  assert.equal(standingLimit(versions, todayNoon), 6 * hour);

  versions.push({ limitMs: 7 * hour, effectiveAtMs: todayNoon });
  assert.equal(standingLimit(versions, limitCutoff(todayEnd, todayNoon)), 7 * hour);
  assert.equal(standingLimit(versions, limitCutoff(todayEnd, todayEnd + hour)), 7 * hour);

  versions.push({ limitMs: 4 * hour, effectiveAtMs: tomorrowNoon });
  assert.equal(standingLimit(versions, limitCutoff(todayEnd, tomorrowNoon)), 7 * hour);
  assert.equal(standingLimit(versions, limitCutoff(todayEnd + day, tomorrowNoon)), 4 * hour);
  assert.equal(standingLimit(versions, limitCutoff(todayEnd + 2 * day, tomorrowNoon + day)), 4 * hour);
});
