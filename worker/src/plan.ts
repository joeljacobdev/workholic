/**
 * The account's plan for the day, one for every Mac. Time blocks are set for chosen dates; every
 * other day follows the daily limit (the limit itself stays in `budget_version`, so past days keep
 * theirs). On a block date only the blocks count. Times are minutes past local midnight on each
 * Mac's own clock, and a block is `[start, end]`, so the stored plan stays a few hundred bytes.
 *
 * `command` is only a script's file name: the Mac runs it from its own commands folder, so the
 * account can choose among scripts already on that Mac but cannot send it code.
 *
 * The shutdown is one for every Mac (`scope` "all"), or each Mac's own entry under `each` ("each"),
 * with the same four fields either way. Plans saved before `scope` read as "all".
 */
export type Block = [number, number];

/** One chosen date and its blocks. A date without blocks is not entered. */
export interface DatedBlocks {
  day: string;
  blocks: Block[];
}

/** How and when a Mac shuts down: the plan's own, or one Mac's entry under `each`. */
export interface MacShutdown {
  /**
   * "time" uses `at`. "plan_end" follows the day: on a block date when the last block ends, on any
   * other day `delay_minutes` past the limit.
   */
  shutdown: "off" | "time" | "plan_end";
  at: number | null;
  delay_minutes: number;
  command: string | null;
}

export interface DayPlan extends MacShutdown {
  /** Soonest first, no date twice. */
  dates: DatedBlocks[];
  /** Outside the blocks, on a block date: cover the screen, or leave it alone. */
  outside: "pause" | "none";
  /** "all": the plan's own shutdown on every Mac. "each": a Mac follows its entry in `each`, or none. */
  scope: "all" | "each";
  /** By device id, only Macs that shut down. Empty under "all". */
  each: Record<string, MacShutdown>;
}

/** A shutdown as Macs before the plan read it. The server still sends one, worked out from the plan. */
export interface ShutdownSchedule {
  when: "time" | "limit";
  after: string | null;
  delay_minutes: number;
  command: string | null;
}

export const DEFAULT_PLAN: DayPlan = {
  dates: [],
  outside: "pause",
  shutdown: "off",
  at: null,
  delay_minutes: 0,
  command: null,
  // A new account starts on each Mac its own way; a plan stored without `scope` still reads as "all".
  scope: "each",
  each: {},
};

const OFF: MacShutdown = { shutdown: "off", at: null, delay_minutes: 0, command: null };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** More Macs than anyone owns, so a request naming many is refused rather than half done. */
export const MAX_DEVICES_PER_REQUEST = 50;
export const MAX_BLOCKS = 8;
/** More dates than a plan needs ahead; a save with more is refused. */
export const MAX_DATES = 60;
const DAY_MINUTES = 24 * 60;
const MAX_DELAY_MINUTES = 12 * 60;
const SCRIPT_NAME = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** The Macs a shutdown is for: distinct device ids, one or more. Anything else is "invalid". */
export function readDeviceIds(value: unknown): string[] | "invalid" {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAX_DEVICES_PER_REQUEST) return "invalid";
  if (!value.every((id) => typeof id === "string" && UUID.test(id))) return "invalid";
  return new Set(value).size === value.length ? (value as string[]) : "invalid";
}

function isMinute(value: unknown, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= max;
}

/** In order, not overlapping, each at least a minute, at most MAX_BLOCKS. Touching blocks are fine. */
function readBlocks(value: unknown): Block[] | null {
  if (!Array.isArray(value) || value.length > MAX_BLOCKS) return null;
  const blocks: Block[] = [];
  let previousEnd = 0;
  for (const block of value) {
    if (!Array.isArray(block) || block.length !== 2) return null;
    const [start, end] = block;
    if (!isMinute(start, DAY_MINUTES) || !isMinute(end, DAY_MINUTES) || start >= end || start < previousEnd) return null;
    blocks.push([start, end]);
    previousEnd = end;
  }
  return blocks;
}

/** The chosen dates: soonest first, no date twice, each with at least one block, at most MAX_DATES. */
function readDates(value: unknown): DatedBlocks[] | null {
  if (!Array.isArray(value) || value.length > MAX_DATES) return null;
  const dates: DatedBlocks[] = [];
  let previous = "";
  for (const entry of value) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) return null;
    const { day, blocks: raw } = entry as Record<string, unknown>;
    if (typeof day !== "string" || !DAY.test(day) || day <= previous) return null;
    const blocks = readBlocks(raw);
    if (!blocks || blocks.length === 0) return null;
    dates.push({ day, blocks });
    previous = day;
  }
  return dates;
}

/** A whole plan, or "invalid". Nothing malformed is ever stored in part. */
export function readDayPlan(value: unknown): DayPlan | "invalid" {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return "invalid";
  const record = value as Record<string, unknown>;
  const dates = readDates(record.dates);
  if (!dates) return "invalid";
  const outside = record.outside ?? "pause";
  if (outside !== "pause" && outside !== "none") return "invalid";
  const own = readShutdown(record);
  if (own === "invalid") return "invalid";
  const scope = record.scope ?? "all";
  if (scope !== "all" && scope !== "each") return "invalid";
  const each: Record<string, MacShutdown> = {};
  if (scope === "each" && record.each !== undefined && record.each !== null) {
    const raw = record.each;
    if (typeof raw !== "object" || Array.isArray(raw)) return "invalid";
    const entries = Object.entries(raw as Record<string, unknown>);
    if (entries.length > MAX_DEVICES_PER_REQUEST) return "invalid";
    for (const [deviceId, value] of entries) {
      if (!UUID.test(deviceId) || value === null || typeof value !== "object" || Array.isArray(value)) return "invalid";
      const entry = readShutdown(value as Record<string, unknown>);
      if (entry === "invalid") return "invalid";
      if (entry.shutdown !== "off") each[deviceId] = entry;
    }
  }
  return { dates, outside, ...own, scope, each };
}

/** A shutdown's four fields, or "invalid". Only what the way of shutting down uses is kept. */
function readShutdown(record: Record<string, unknown>): MacShutdown | "invalid" {
  const shutdown = record.shutdown ?? "off";
  if (shutdown !== "off" && shutdown !== "time" && shutdown !== "plan_end") return "invalid";
  let at: number | null = null;
  if (shutdown === "time") {
    if (!isMinute(record.at, DAY_MINUTES - 1)) return "invalid";
    at = record.at;
  }
  let delay = 0;
  if (shutdown === "plan_end") {
    delay = (record.delay_minutes ?? 0) as number;
    if (!isMinute(delay, MAX_DELAY_MINUTES)) return "invalid";
  }
  let command: string | null = null;
  if (shutdown !== "off" && record.command !== undefined && record.command !== null && record.command !== "") {
    if (typeof record.command !== "string" || !SCRIPT_NAME.test(record.command) || record.command.includes("..")) return "invalid";
    command = record.command;
  }
  return { shutdown, at, delay_minutes: delay, command };
}

/** How `deviceId` shuts down under this plan: the plan's own way, or its entry, or not at all. */
export function shutdownFor(plan: DayPlan, deviceId: string | undefined): MacShutdown {
  if (plan.scope !== "each") return { shutdown: plan.shutdown, at: plan.at, delay_minutes: plan.delay_minutes, command: plan.command };
  return (deviceId !== undefined && plan.each[deviceId]) || OFF;
}

/** The blocks of `day` when it is a block date, else none: that day follows the daily limit. */
export function blocksOn(plan: DayPlan, day: string): Block[] {
  return plan.dates.find((entry) => entry.day === day)?.blocks ?? [];
}

/** The day before a "YYYY-MM-DD" day. */
function dayBefore(day: string): string {
  const date = new Date(`${day}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() - 1);
  return date.toISOString().slice(0, 10);
}

/**
 * The plan without dates before yesterday, so the list does not grow forever. Yesterday stays, as
 * each Mac follows its own clock.
 */
export function withoutPastDates(plan: DayPlan, today: string): DayPlan {
  const from = dayBefore(today);
  return { ...plan, dates: plan.dates.filter((entry) => entry.day >= from) };
}

function clock(minute: number): string {
  return `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
}

/**
 * The shutdown in the shape Macs before the plan understand, for `day` and `deviceId`. The last block
 * ending at midnight shuts down at 23:59, the latest clock time they read. None when nothing is due that day.
 */
export function legacyShutdown(plan: DayPlan, day: string, deviceId?: string): ShutdownSchedule | null {
  const own = shutdownFor(plan, deviceId);
  const command = own.command;
  switch (own.shutdown) {
    case "time":
      return { when: "time", after: clock(own.at ?? 0), delay_minutes: 0, command };
    case "plan_end": {
      const blocks = blocksOn(plan, day);
      if (blocks.length === 0) return { when: "limit", after: null, delay_minutes: own.delay_minutes, command };
      return { when: "time", after: clock(Math.min(blocks[blocks.length - 1][1], DAY_MINUTES - 1)), delay_minutes: 0, command };
    }
    default:
      return null;
  }
}

/**
 * The one-time step for plans stored before dates, as a save would write them in the new shape. The
 * weekday and weekend blocks are dropped; today's own blocks become a date when that day is `today` or
 * later; the shutdown after the limit and the one after the last block both become "plan_end". A plan
 * already in the new shape comes back as it is.
 */
export function migrateDayPlan(stored: unknown, today: string): DayPlan | "invalid" {
  if (stored === null || typeof stored !== "object" || Array.isArray(stored)) return "invalid";
  const record = stored as Record<string, unknown>;
  if (!("mode" in record) && Array.isArray(record.dates)) return readDayPlan(record);
  const shutdownOf = (entry: Record<string, unknown>) => ({
    ...entry,
    shutdown: entry.shutdown === "limit" || entry.shutdown === "last_block" ? "plan_end" : entry.shutdown,
  });
  const dates: DatedBlocks[] = [];
  const own = record.today as Record<string, unknown> | null | undefined;
  if (own && typeof own === "object" && typeof own.day === "string" && own.day >= today && Array.isArray(own.blocks) && own.blocks.length > 0) {
    dates.push({ day: own.day, blocks: own.blocks as Block[] });
  }
  const each: Record<string, unknown> = {};
  if (record.each && typeof record.each === "object" && !Array.isArray(record.each)) {
    for (const [deviceId, entry] of Object.entries(record.each as Record<string, unknown>)) {
      each[deviceId] = entry && typeof entry === "object" ? shutdownOf(entry as Record<string, unknown>) : entry;
    }
  }
  const { mode: _mode, weekdays: _weekdays, weekends: _weekends, today: _today, ...rest } = record;
  return readDayPlan({ ...shutdownOf(rest), dates, each });
}
