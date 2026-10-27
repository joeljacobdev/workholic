/**
 * The account's plan for the day, one for every Mac. Either a daily limit (the limit itself stays
 * in `budget_version`, so past days keep theirs) or time blocks, one set for weekdays and one for
 * weekends, which today can replace. Times are minutes past local midnight on each Mac's own clock,
 * and a block is `[start, end]`, so the stored plan stays a few hundred bytes.
 *
 * `command` is only a script's file name: the Mac runs it from its own commands folder, so the
 * account can choose among scripts already on that Mac but cannot send it code.
 *
 * The shutdown is one for every Mac (`scope` "all"), or each Mac's own entry under `each` ("each"),
 * with the same four fields either way. Plans saved before `scope` read as "all".
 */
export type Block = [number, number];

/** How and when a Mac shuts down: the plan's own, or one Mac's entry under `each`. */
export interface MacShutdown {
  /** "time" uses `at`; "limit" waits `delay_minutes` past the limit; "last_block" is when the last block ends. */
  shutdown: "off" | "time" | "limit" | "last_block";
  at: number | null;
  delay_minutes: number;
  command: string | null;
}

export interface DayPlan extends MacShutdown {
  mode: "limit" | "planner";
  weekdays: Block[];
  weekends: Block[];
  /** Blocks for one day only, in place of the usual set. */
  today: { day: string; blocks: Block[] } | null;
  /** Outside the blocks, in planner mode: cover the screen, or leave it alone. */
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
  mode: "limit",
  weekdays: [],
  weekends: [],
  today: null,
  outside: "pause",
  shutdown: "off",
  at: null,
  delay_minutes: 0,
  command: null,
  scope: "all",
  each: {},
};

const OFF: MacShutdown = { shutdown: "off", at: null, delay_minutes: 0, command: null };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** More Macs than anyone owns, so a request naming many is refused rather than half done. */
export const MAX_DEVICES_PER_REQUEST = 50;
export const MAX_BLOCKS = 8;
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

/** A whole plan, or "invalid". Nothing malformed is ever stored in part. */
export function readDayPlan(value: unknown): DayPlan | "invalid" {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return "invalid";
  const record = value as Record<string, unknown>;
  const mode = record.mode;
  if (mode !== "limit" && mode !== "planner") return "invalid";
  const weekdays = readBlocks(record.weekdays ?? []);
  const weekends = readBlocks(record.weekends ?? []);
  if (!weekdays || !weekends) return "invalid";
  let today: DayPlan["today"] = null;
  if (record.today !== undefined && record.today !== null) {
    const raw = record.today as Record<string, unknown>;
    const blocks = readBlocks(raw?.blocks);
    if (typeof raw !== "object" || typeof raw.day !== "string" || !DAY.test(raw.day) || !blocks) return "invalid";
    today = { day: raw.day, blocks };
  }
  const outside = record.outside ?? "pause";
  if (outside !== "pause" && outside !== "none") return "invalid";
  const own = readShutdown(record, mode);
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
      const entry = readShutdown(value as Record<string, unknown>, mode);
      if (entry === "invalid") return "invalid";
      if (entry.shutdown !== "off") each[deviceId] = entry;
    }
  }
  return { mode, weekdays, weekends, today, outside, ...own, scope, each };
}

/** A shutdown's four fields, or "invalid". Only what the way of shutting down uses is kept. */
function readShutdown(record: Record<string, unknown>, mode: DayPlan["mode"]): MacShutdown | "invalid" {
  const shutdown = record.shutdown ?? "off";
  if (shutdown !== "off" && shutdown !== "time" && shutdown !== "limit" && shutdown !== "last_block") return "invalid";
  // Each way of shutting down belongs to one mode, or to both.
  if ((shutdown === "limit" && mode !== "limit") || (shutdown === "last_block" && mode !== "planner")) return "invalid";
  let at: number | null = null;
  if (shutdown === "time") {
    if (!isMinute(record.at, DAY_MINUTES - 1)) return "invalid";
    at = record.at;
  }
  let delay = 0;
  if (shutdown === "limit") {
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

/** The blocks that hold on `day`: today's own, or the usual set for a weekday or a weekend. */
export function blocksFor(plan: DayPlan, day: string, weekend: boolean): Block[] {
  if (plan.today?.day === day) return plan.today.blocks;
  return weekend ? plan.weekends : plan.weekdays;
}

function clock(minute: number): string {
  return `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
}

/**
 * The shutdown in the shape Macs before the plan understand, for `day` and `deviceId`. The last block
 * ending at midnight shuts down at 23:59, the latest clock time they read. None when nothing is due that day.
 */
export function legacyShutdown(plan: DayPlan, day: string, weekend: boolean, deviceId?: string): ShutdownSchedule | null {
  const own = shutdownFor(plan, deviceId);
  const command = own.command;
  switch (own.shutdown) {
    case "time":
      return { when: "time", after: clock(own.at ?? 0), delay_minutes: 0, command };
    case "limit":
      return { when: "limit", after: null, delay_minutes: own.delay_minutes, command };
    case "last_block": {
      const blocks = blocksFor(plan, day, weekend);
      if (blocks.length === 0) return null;
      return { when: "time", after: clock(Math.min(blocks[blocks.length - 1][1], DAY_MINUTES - 1)), delay_minutes: 0, command };
    }
    default:
      return null;
  }
}
