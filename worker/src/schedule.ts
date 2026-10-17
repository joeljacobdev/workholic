/**
 * A Mac's daily scheduled shutdown. It comes due either after a clock time (`when: "time"`, `after`
 * in the Mac's own local time) or `delay_minutes` after today's limit is crossed (`when: "limit"`).
 * If `command` names a script, the Mac also waits for the time it prints: whichever is later wins.
 * `command` is only a script's file name: the Mac runs it from its own commands folder, so the
 * account can choose among scripts already on that Mac but cannot send it code.
 */
export interface ShutdownSchedule {
  when: "time" | "limit";
  after: string | null;
  delay_minutes: number;
  command: string | null;
}

const CLOCK = /^([01]\d|2[0-3]):[0-5]\d$/;
const SCRIPT_NAME = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}$/;
const MAX_DELAY_MINUTES = 12 * 60;

/** Null turns the schedule off. Anything malformed is "invalid", never a partial schedule. */
export function readShutdownSchedule(value: unknown): ShutdownSchedule | null | "invalid" {
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) return "invalid";
  const record = value as Record<string, unknown>;
  // The first version had no `when` and was always a clock time.
  const when = record.when ?? "time";
  let command: string | null = null;
  if (record.command !== undefined && record.command !== null && record.command !== "") {
    if (typeof record.command !== "string" || !SCRIPT_NAME.test(record.command) || record.command.includes("..")) return "invalid";
    command = record.command;
  }
  if (when === "time") {
    if (typeof record.after !== "string" || !CLOCK.test(record.after)) return "invalid";
    return { when, after: record.after, delay_minutes: 0, command };
  }
  if (when === "limit") {
    const delay = record.delay_minutes ?? 0;
    if (typeof delay !== "number" || !Number.isInteger(delay) || delay < 0 || delay > MAX_DELAY_MINUTES) return "invalid";
    return { when, after: null, delay_minutes: delay, command };
  }
  return "invalid";
}
