/**
 * A Mac's scheduled shutdown. It shuts down after `after` (its own local time), once past today's
 * limit if `after_limit`, and not before the time `command` prints if one is named.
 * `command` is only a script's file name: the Mac runs it from its own commands folder, so the
 * account can choose among scripts already on that Mac but cannot send it code.
 */
export interface ShutdownSchedule {
  after: string;
  after_limit: boolean;
  command: string | null;
}

const CLOCK = /^([01]\d|2[0-3]):[0-5]\d$/;
const SCRIPT_NAME = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}$/;

/** Null turns the schedule off. Anything malformed is "invalid", never a partial schedule. */
export function readShutdownSchedule(value: unknown): ShutdownSchedule | null | "invalid" {
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) return "invalid";
  const record = value as Record<string, unknown>;
  if (typeof record.after !== "string" || !CLOCK.test(record.after)) return "invalid";
  if (record.after_limit !== undefined && typeof record.after_limit !== "boolean") return "invalid";
  let command: string | null = null;
  if (record.command !== undefined && record.command !== null && record.command !== "") {
    if (typeof record.command !== "string" || !SCRIPT_NAME.test(record.command) || record.command.includes("..")) return "invalid";
    command = record.command;
  }
  return { after: record.after, after_limit: record.after_limit === true, command };
}
