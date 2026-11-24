import assert from "node:assert/strict";
import test from "node:test";
import * as planModule from "../src/plan.ts";
import { DEFAULT_PLAN, MAX_BLOCKS, MAX_DATES, MAX_DEVICES_PER_REQUEST, blocksOn, legacyShutdown, readDayPlan, readDeviceIds, shutdownFor, withoutPastDates } from "../src/plan.ts";

const planner = {
  dates: [{ day: "2026-10-27", blocks: [[540, 720], [780, 1080]] }, { day: "2026-10-31", blocks: [[600, 660]] }],
  outside: "pause",
  shutdown: "plan_end",
  command: null,
};

test("a plan with no dates and nothing else", () => {
  assert.deepEqual(readDayPlan({ dates: [] }), { ...DEFAULT_PLAN, scope: "all" });
  assert.equal(readDayPlan({}), "invalid", "the dates are always sent");
});

test("a plan with blocks on two dates", () => {
  assert.deepEqual(readDayPlan(planner), { ...planner, at: null, delay_minutes: 0, scope: "all", each: {} });
});

test("a shutdown at a set time, with a script", () => {
  for (const dates of [[], planner.dates]) {
    const plan = readDayPlan({ dates, shutdown: "time", at: 1320, command: "last-call.sh" });
    assert.notEqual(plan, "invalid");
    assert.equal((plan as { at: number }).at, 1320);
    assert.equal((plan as { command: string }).command, "last-call.sh");
  }
  assert.equal(readDayPlan({ dates: [], shutdown: "time", at: 1440 }), "invalid", "the last minute is 23:59");
  assert.equal(readDayPlan({ dates: [], shutdown: "time" }), "invalid");
});

test("the wait after the limit is up to twelve hours", () => {
  assert.equal((readDayPlan({ dates: [], shutdown: "plan_end", delay_minutes: 30 }) as { delay_minutes: number }).delay_minutes, 30);
  for (const delay_minutes of [-1, 1.5, 721, "30"]) {
    assert.equal(readDayPlan({ dates: [], shutdown: "plan_end", delay_minutes }), "invalid", String(delay_minutes));
  }
});

test("only what the shutdown uses is kept", () => {
  const plan = readDayPlan({ dates: [], shutdown: "off", at: 600, delay_minutes: 5, command: "x" });
  assert.deepEqual(plan, { ...DEFAULT_PLAN, scope: "all" });
});

test("at most MAX_DATES dates", () => {
  const day = (index: number) => new Date(Date.UTC(2026, 11, 1) + index * 86_400_000).toISOString().slice(0, 10);
  const dates = (count: number) => Array.from({ length: count }, (_, index) => ({ day: day(index), blocks: [[540, 600]] }));
  assert.notEqual(readDayPlan({ dates: dates(MAX_DATES) }), "invalid");
  assert.equal(readDayPlan({ dates: dates(MAX_DATES + 1) }), "invalid");
});

test("dates before yesterday are dropped on a save", () => {
  const plan = readDayPlan({ dates: [{ day: "2026-11-22", blocks: [[540, 600]] }, { day: "2026-11-23", blocks: [[540, 600]] }, { day: "2026-12-01", blocks: [[540, 600]] }] });
  if (plan === "invalid") return assert.fail();
  assert.deepEqual(withoutPastDates(plan, "2026-11-24").dates.map((entry) => entry.day), ["2026-11-23", "2026-12-01"]);
  assert.deepEqual(withoutPastDates(plan, "2026-12-01").dates.map((entry) => entry.day), ["2026-12-01"], "across a month");
});

test("blocks are in order, apart, and inside the day", () => {
  for (const blocks of [
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
    assert.equal(readDayPlan({ dates: [{ day: "2026-10-27", blocks }] }), "invalid", JSON.stringify(blocks));
  }
  assert.notEqual(readDayPlan({ dates: [{ day: "2026-10-27", blocks: [[0, 720], [720, 1440]] }] }), "invalid", "touching blocks and a whole day are fine");
});

test("the command is a bare script name, never a path or shell", () => {
  for (const command of ["../x", "a/b", "/bin/sh", ".hidden", "a..b", "rm -rf", "$(id)", 7]) {
    assert.equal(readDayPlan({ dates: [], shutdown: "time", at: 600, command }), "invalid", String(command));
  }
});

test("other shapes are refused", () => {
  for (const value of [null, [], "limit", { dates: "2026-10-27" }, { dates: [], outside: "lock" }, { dates: [], shutdown: "now" }]) {
    assert.equal(readDayPlan(value), "invalid", JSON.stringify(value));
  }
});

test("the blocks for a day: the date's own, else none", () => {
  const plan = readDayPlan(planner);
  assert.notEqual(plan, "invalid");
  if (plan === "invalid") return;
  assert.deepEqual(blocksOn(plan, "2026-10-27"), planner.dates[0].blocks);
  assert.deepEqual(blocksOn(plan, "2026-10-31"), planner.dates[1].blocks);
  assert.deepEqual(blocksOn(plan, "2026-10-28"), []);
});

test("older Macs get the shutdown as a clock time or a limit", () => {
  const plan = readDayPlan(planner);
  if (plan === "invalid") return assert.fail();
  assert.deepEqual(legacyShutdown(plan, "2026-10-27"), { when: "time", after: "18:00", delay_minutes: 0, command: null });
  assert.deepEqual(legacyShutdown(plan, "2026-10-31"), { when: "time", after: "11:00", delay_minutes: 0, command: null });
  assert.deepEqual(legacyShutdown(plan, "2026-10-28"), { when: "limit", after: null, delay_minutes: 0, command: null }, "no blocks that day, after the limit");
  assert.deepEqual(legacyShutdown({ ...DEFAULT_PLAN, scope: "all", shutdown: "time", at: 1290, command: "cal" }, "2026-10-27"), { when: "time", after: "21:30", delay_minutes: 0, command: "cal" });
  assert.deepEqual(legacyShutdown({ ...DEFAULT_PLAN, scope: "all", shutdown: "plan_end", delay_minutes: 30 }, "2026-10-27"), { when: "limit", after: null, delay_minutes: 30, command: null });
  assert.equal(legacyShutdown(DEFAULT_PLAN, "2026-10-27"), null);
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

test("each Mac can have its own shutdown; plans before this read as the same on every Mac", () => {
  const plan = readDayPlan({ dates: [] });
  assert.notEqual(plan, "invalid");
  if (plan === "invalid") return;
  assert.equal(plan.scope, "all");
  assert.deepEqual(plan.each, {});
  assert.equal(DEFAULT_PLAN.scope, "each", "a new account starts on each its own way");
  const own = readDayPlan({
    dates: [], scope: "each", shutdown: "off",
    each: { [macA]: { shutdown: "time", at: 1290, command: "cal" }, [macB]: { shutdown: "plan_end", delay_minutes: 30 } },
  });
  if (own === "invalid") return assert.fail("a valid plan with entries per Mac");
  assert.deepEqual(own.each, {
    [macA]: { shutdown: "time", at: 1290, delay_minutes: 0, command: "cal" },
    [macB]: { shutdown: "plan_end", at: null, delay_minutes: 30, command: null },
  });
  assert.deepEqual(shutdownFor(own, macA), own.each[macA]);
  assert.deepEqual(shutdownFor(own, "00000000-0000-4000-8000-000000000000"), { shutdown: "off", at: null, delay_minutes: 0, command: null }, "a Mac not listed does not shut down");
  assert.deepEqual(legacyShutdown(own, "2026-10-27", macA), { when: "time", after: "21:30", delay_minutes: 0, command: "cal" });
  assert.deepEqual(legacyShutdown(own, "2026-10-27", macB), { when: "limit", after: null, delay_minutes: 30, command: null });
  assert.equal(legacyShutdown(own, "2026-10-27", "00000000-0000-4000-8000-000000000000"), null);
  assert.equal(legacyShutdown(own, "2026-10-27"), null, "no Mac named, no shutdown under each");
});

test("under one schedule for every Mac the entries are dropped, and off entries are never kept", () => {
  const shared = readDayPlan({ dates: [], scope: "all", shutdown: "time", at: 600, each: { [macA]: { shutdown: "time", at: 1290 } } });
  if (shared === "invalid") return assert.fail();
  assert.deepEqual(shared.each, {});
  assert.deepEqual(shutdownFor(shared, macA), { shutdown: "time", at: 600, delay_minutes: 0, command: null });
  assert.deepEqual(legacyShutdown(shared, "2026-10-27", macB)?.after, "10:00");
  const sparse = readDayPlan({ dates: [], scope: "each", each: { [macA]: { shutdown: "off", at: 600 }, [macB]: { shutdown: "time", at: 60 } } });
  if (sparse === "invalid") return assert.fail();
  assert.deepEqual(Object.keys(sparse.each), [macB]);
});

test("entries per Mac follow the plan's own rules", () => {
  for (const each of [
    { [macA]: { shutdown: "last_block" } },
    { [macA]: { shutdown: "limit" } },
    { [macA]: { shutdown: "time" } },
    { [macA]: { shutdown: "time", at: 1440 } },
    { [macA]: { shutdown: "plan_end", delay_minutes: 721 } },
    { [macA]: { shutdown: "time", at: 600, command: "../x" } },
    { [macA]: { shutdown: "now" } },
    { [macA]: "time" },
    { "not-a-uuid": { shutdown: "time", at: 600 } },
    [{ shutdown: "time", at: 600 }],
    Object.fromEntries(Array.from({ length: MAX_DEVICES_PER_REQUEST + 1 }, (_, index) => [`00000000-0000-4000-8000-${String(index).padStart(12, "0")}`, { shutdown: "time", at: 600 }])),
  ]) {
    assert.equal(readDayPlan({ dates: [], scope: "each", each }), "invalid", JSON.stringify(each));
  }
  assert.equal(readDayPlan({ dates: [], scope: "some" }), "invalid");
  assert.notEqual(readDayPlan({ dates: [], scope: "each", each: { [macA]: { shutdown: "plan_end" } } }), "invalid");
});

// Blocks on chosen dates; every other day follows the daily limit. The new functions are reached
// through the module object so the tests above still load before the build exists.
const dated = {
  dates: [{ day: "2026-12-01", blocks: [[540, 720], [780, 1080]] }],
  outside: "pause",
  shutdown: "plan_end",
  delay_minutes: 30,
  command: null,
};
const PLAN_DAY = "2026-12-01";
const FREE_DAY = "2026-12-02";

test("a plan with only dates, no mode, is valid", () => {
  const plan = readDayPlan(dated);
  assert.notEqual(plan, "invalid");
  assert.deepEqual((plan as { dates: unknown }).dates, dated.dates);
  assert.equal((plan as { shutdown: string }).shutdown, "plan_end");
  assert.equal("mode" in (plan as object), false);
  assert.equal("weekdays" in (plan as object), false);
  assert.equal("today" in (plan as object), false);
});

test("a plan with no dates is valid, and the old mode shape is no longer read", () => {
  assert.notEqual(readDayPlan({ dates: [] }), "invalid");
  assert.equal(readDayPlan({ dates: [{ day: PLAN_DAY, blocks: [] }] }), "invalid", "a date without blocks is not entered");
  assert.equal(readDayPlan({ dates: [{ day: "12/01/2026", blocks: [[540, 600]] }] }), "invalid");
  assert.equal(readDayPlan({ dates: [{ day: PLAN_DAY, blocks: [[600, 540]] }] }), "invalid");
  assert.equal(readDayPlan({ dates: [{ day: PLAN_DAY, blocks: [[540, 700], [600, 800]] }] }), "invalid", "blocks do not overlap");
  assert.equal(readDayPlan({ dates: [{ day: PLAN_DAY, blocks: [[540, 600]] }, { day: PLAN_DAY, blocks: [[700, 800]] }] }), "invalid", "no repeated date");
  assert.equal(readDayPlan({ dates: [{ day: "2026-12-02", blocks: [[540, 600]] }, { day: PLAN_DAY, blocks: [[540, 600]] }] }), "invalid", "dates are in order");
});

test("plan_end is a choice in the plan and in each Mac's entry", () => {
  const macA = "8b6c1c0e-3a1a-4e0a-9f1a-0c2b7a6d5e11";
  const plan = readDayPlan({ ...dated, scope: "each", each: { [macA]: { shutdown: "plan_end", delay_minutes: 15 } } });
  assert.notEqual(plan, "invalid");
  assert.equal((plan as { each: Record<string, { shutdown: string; delay_minutes: number }> }).each[macA].shutdown, "plan_end");
  assert.equal((plan as { each: Record<string, { delay_minutes: number }> }).each[macA].delay_minutes, 15);
  assert.equal(readDayPlan({ ...dated, delay_minutes: 721 }), "invalid");
  for (const old of ["limit", "last_block"]) assert.equal(readDayPlan({ ...dated, shutdown: old }), "invalid", old);
});

test("blocksOn gives the blocks of a block date and nothing on any other day", () => {
  const plan = readDayPlan(dated);
  assert.notEqual(plan, "invalid");
  const { blocksOn } = planModule as unknown as { blocksOn: (plan: unknown, day: string) => number[][] };
  assert.deepEqual(blocksOn(plan, PLAN_DAY), dated.dates[0].blocks);
  assert.deepEqual(blocksOn(plan, FREE_DAY), []);
  assert.deepEqual(blocksOn(plan, "2026-11-30"), []);
});

test("plan_end follows the day: the last block's end on a block date, the limit plus the wait on other days", () => {
  const plan = readDayPlan(dated);
  assert.notEqual(plan, "invalid");
  const legacy = planModule.legacyShutdown as unknown as (plan: unknown, day: string, deviceId?: string) => unknown;
  assert.deepEqual(legacy(plan, PLAN_DAY), { when: "time", after: "18:00", delay_minutes: 0, command: null });
  assert.deepEqual(legacy(plan, FREE_DAY), { when: "limit", after: null, delay_minutes: 30, command: null });
});

test("plan_end on a block date ending at midnight shuts down at 23:59", () => {
  const plan = readDayPlan({ ...dated, dates: [{ day: PLAN_DAY, blocks: [[1200, 1440]] }] });
  const legacy = planModule.legacyShutdown as unknown as (plan: unknown, day: string) => { after: string };
  assert.equal(legacy(plan, PLAN_DAY).after, "23:59");
});

test("off and a set time do not depend on the day", () => {
  const legacy = planModule.legacyShutdown as unknown as (plan: unknown, day: string) => unknown;
  const timed = readDayPlan({ ...dated, shutdown: "time", at: 1290 });
  assert.deepEqual(legacy(timed, PLAN_DAY), { when: "time", after: "21:30", delay_minutes: 0, command: null });
  assert.deepEqual(legacy(timed, FREE_DAY), { when: "time", after: "21:30", delay_minutes: 0, command: null });
  assert.equal(legacy(readDayPlan({ ...dated, shutdown: "off" }), PLAN_DAY), null);
});

// The stored-row step: the plan as an account saved it before dates, turned into the new shape.
// `migrateDayPlan(stored, today)` takes the parsed old JSON and today's "YYYY-MM-DD" and returns the new plan.
const migrate = (stored: unknown, today = "2026-11-24") =>
  (planModule as unknown as { migrateDayPlan: (stored: unknown, today: string) => Record<string, unknown> }).migrateDayPlan(stored, today);
const oldPlanner = {
  mode: "planner",
  weekdays: [[540, 720], [780, 1080]],
  weekends: [[600, 660]],
  today: null,
  outside: "none",
  shutdown: "last_block",
  at: null,
  delay_minutes: 0,
  command: "cal.sh",
  scope: "all",
  each: {},
};

test("a blocks-mode plan loses mode, weekdays and weekends, and last_block becomes plan_end", () => {
  const out = migrate(oldPlanner);
  for (const key of ["mode", "weekdays", "weekends", "today"]) assert.equal(key in out, false, key);
  assert.deepEqual(out.dates, []);
  assert.equal(out.shutdown, "plan_end");
  assert.equal(out.command, "cal.sh");
  assert.equal(out.outside, "none");
  assert.notEqual(readDayPlan(out), "invalid", "the result is a plan the server reads");
});

test("limit and last_block both become plan_end, with the wait kept; time and off stay", () => {
  const macA = "8b6c1c0e-3a1a-4e0a-9f1a-0c2b7a6d5e11";
  const macB = "1f0e2d3c-4b5a-4968-8776-655443322110";
  const macC = "00000000-0000-4000-8000-000000000003";
  const out = migrate({
    mode: "limit", weekdays: [], weekends: [], today: null, outside: "pause",
    shutdown: "limit", at: null, delay_minutes: 45, command: null,
    scope: "each",
    each: {
      [macA]: { shutdown: "limit", at: null, delay_minutes: 30, command: null },
      [macB]: { shutdown: "time", at: 1290, delay_minutes: 0, command: "cal.sh" },
      [macC]: { shutdown: "last_block", at: null, delay_minutes: 0, command: null },
    },
  });
  assert.equal(out.shutdown, "plan_end");
  assert.equal(out.delay_minutes, 45);
  const each = out.each as Record<string, { shutdown: string; delay_minutes: number; at: number | null }>;
  assert.equal(each[macA].shutdown, "plan_end");
  assert.equal(each[macA].delay_minutes, 30);
  assert.equal(each[macB].shutdown, "time");
  assert.equal(each[macB].at, 1290);
  assert.equal(each[macC].shutdown, "plan_end");
  assert.notEqual(readDayPlan(out), "invalid");
  assert.equal(migrate({ mode: "limit", shutdown: "off" }).shutdown, "off");
});

test("yesterday's today is dropped; a today for today or later becomes a date entry", () => {
  const past = migrate({ ...oldPlanner, today: { day: "2026-11-23", blocks: [[600, 900]] } });
  assert.deepEqual(past.dates, []);
  assert.equal("today" in past, false);

  const now = migrate({ ...oldPlanner, today: { day: "2026-11-24", blocks: [[600, 900]] } });
  assert.deepEqual(now.dates, [{ day: "2026-11-24", blocks: [[600, 900]] }]);

  const later = migrate({ ...oldPlanner, today: { day: "2026-11-25", blocks: [[600, 900]] } });
  assert.deepEqual(later.dates, [{ day: "2026-11-25", blocks: [[600, 900]] }]);

  const empty = migrate({ ...oldPlanner, today: { day: "2026-11-24", blocks: [] } });
  assert.deepEqual(empty.dates, [], "a date without blocks is not entered");
  assert.notEqual(readDayPlan(now), "invalid");
});

test("migrating a plan already in the new shape changes nothing", () => {
  const plan = readDayPlan(dated);
  assert.deepEqual(migrate(plan), plan);
});
