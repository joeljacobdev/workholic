import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_PLAN, MAX_BLOCKS, MAX_DEVICES_PER_REQUEST, blocksFor, legacyShutdown, readDayPlan, readDeviceIds } from "../src/plan.ts";

const planner = {
  mode: "planner",
  weekdays: [[540, 720], [780, 1080]],
  weekends: [[600, 660]],
  today: null,
  outside: "pause",
  shutdown: "last_block",
  command: null,
};

test("a limit plan with nothing else", () => {
  assert.deepEqual(readDayPlan({ mode: "limit" }), DEFAULT_PLAN);
});

test("a planner with weekday and weekend blocks", () => {
  assert.deepEqual(readDayPlan(planner), { ...planner, at: null, delay_minutes: 0 });
});

test("a shutdown at a set time, in either mode, with a script", () => {
  for (const mode of ["limit", "planner"]) {
    const plan = readDayPlan({ mode, shutdown: "time", at: 1320, command: "last-call.sh" });
    assert.notEqual(plan, "invalid");
    assert.equal((plan as { at: number }).at, 1320);
    assert.equal((plan as { command: string }).command, "last-call.sh");
  }
  assert.equal(readDayPlan({ mode: "limit", shutdown: "time", at: 1440 }), "invalid", "the last minute is 23:59");
  assert.equal(readDayPlan({ mode: "limit", shutdown: "time" }), "invalid");
});

test("each way of shutting down belongs to its mode", () => {
  assert.equal(readDayPlan({ mode: "planner", shutdown: "limit" }), "invalid");
  assert.equal(readDayPlan({ mode: "limit", shutdown: "last_block" }), "invalid");
  assert.equal((readDayPlan({ mode: "limit", shutdown: "limit", delay_minutes: 30 }) as { delay_minutes: number }).delay_minutes, 30);
  for (const delay_minutes of [-1, 1.5, 721, "30"]) {
    assert.equal(readDayPlan({ mode: "limit", shutdown: "limit", delay_minutes }), "invalid", String(delay_minutes));
  }
});

test("only what the shutdown uses is kept", () => {
  const plan = readDayPlan({ mode: "limit", shutdown: "off", at: 600, delay_minutes: 5, command: "x" });
  assert.deepEqual(plan, DEFAULT_PLAN);
});

test("blocks are in order, apart, and inside the day", () => {
  for (const weekdays of [
    [[720, 540]],
    [[540, 540]],
    [[540, 720], [700, 800]],
    [[780, 1080], [540, 720]],
    [[-1, 60]],
    [[0, 1441]],
    [[540, 720.5]],
    [[540]],
    "09:00-12:00",
    Array.from({ length: MAX_BLOCKS + 1 }, (_, index) => [index * 60, index * 60 + 30]),
  ]) {
    assert.equal(readDayPlan({ mode: "planner", weekdays }), "invalid", JSON.stringify(weekdays));
  }
  assert.notEqual(readDayPlan({ mode: "planner", weekdays: [[0, 720], [720, 1440]] }), "invalid", "touching blocks and a whole day are fine");
});

test("today's own blocks name their day", () => {
  const today = { day: "2026-10-26", blocks: [[600, 900]] };
  assert.deepEqual((readDayPlan({ ...planner, today }) as { today: unknown }).today, today);
  assert.equal(readDayPlan({ ...planner, today: { day: "today", blocks: [] } }), "invalid");
  assert.equal(readDayPlan({ ...planner, today: { day: "2026-10-26" } }), "invalid");
  assert.equal(readDayPlan({ ...planner, today: "2026-10-26" }), "invalid");
});

test("the command is a bare script name, never a path or shell", () => {
  for (const command of ["../x", "a/b", "/bin/sh", ".hidden", "a..b", "rm -rf", "$(id)", 7]) {
    assert.equal(readDayPlan({ mode: "limit", shutdown: "time", at: 600, command }), "invalid", String(command));
  }
});

test("other shapes are refused", () => {
  for (const value of [null, [], "limit", { mode: "tasks" }, { mode: "planner", outside: "lock" }, { mode: "limit", shutdown: "now" }]) {
    assert.equal(readDayPlan(value), "invalid", JSON.stringify(value));
  }
});

test("the blocks for a day: today's own, else weekday or weekend", () => {
  const plan = readDayPlan({ ...planner, today: { day: "2026-10-26", blocks: [[600, 900]] } });
  assert.notEqual(plan, "invalid");
  if (plan === "invalid") return;
  assert.deepEqual(blocksFor(plan, "2026-10-26", false), [[600, 900]]);
  assert.deepEqual(blocksFor(plan, "2026-10-27", false), planner.weekdays);
  assert.deepEqual(blocksFor(plan, "2026-10-31", true), planner.weekends);
});

test("older Macs get the shutdown as a clock time or a limit", () => {
  const plan = readDayPlan(planner);
  if (plan === "invalid") return assert.fail();
  assert.deepEqual(legacyShutdown(plan, "2026-10-27", false), { when: "time", after: "18:00", delay_minutes: 0, command: null });
  assert.deepEqual(legacyShutdown(plan, "2026-10-31", true), { when: "time", after: "11:00", delay_minutes: 0, command: null });
  assert.equal(legacyShutdown({ ...plan, weekends: [] }, "2026-10-31", true), null, "no blocks that day, no shutdown");
  assert.deepEqual(legacyShutdown({ ...plan, weekdays: [[1200, 1440]] }, "2026-10-27", false)?.after, "23:59");
  assert.deepEqual(legacyShutdown({ ...DEFAULT_PLAN, shutdown: "time", at: 1290, command: "cal" }, "2026-10-27", false), { when: "time", after: "21:30", delay_minutes: 0, command: "cal" });
  assert.deepEqual(legacyShutdown({ ...DEFAULT_PLAN, shutdown: "limit", delay_minutes: 30 }, "2026-10-27", false), { when: "limit", after: null, delay_minutes: 30, command: null });
  assert.equal(legacyShutdown(DEFAULT_PLAN, "2026-10-27", false), null);
});

const macA = "8b6c1c0e-3a1a-4e0a-9f1a-0c2b7a6d5e11";
const macB = "1f0e2d3c-4b5a-4968-8776-655443322110";

test("the Macs a request is for are distinct device ids", () => {
  assert.deepEqual(readDeviceIds([macA]), [macA]);
  assert.deepEqual(readDeviceIds([macA, macB]), [macA, macB]);
});

test("an empty, repeated, or malformed list of Macs is refused whole", () => {
  for (const value of [[], [macA, macA], [macA, "not-a-uuid"], [macA, 7], macA, null, undefined, {}, [macA.toUpperCase()]]) {
    assert.equal(readDeviceIds(value), "invalid", JSON.stringify(value));
  }
});

test("more Macs than anyone owns is refused", () => {
  const many = Array.from({ length: MAX_DEVICES_PER_REQUEST + 1 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`);
  assert.equal(readDeviceIds(many), "invalid");
  assert.equal((readDeviceIds(many.slice(1)) as string[]).length, MAX_DEVICES_PER_REQUEST);
});
