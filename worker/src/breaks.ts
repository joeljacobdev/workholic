// Break settings shared by the web app and every Mac on the account.
// Which pause comes next is per Mac and is not stored here.

export interface BreakItem {
  id: string;
  message: string;
  minutes: number;
  rest: boolean;
}

/**
 * A pause once a hand-started session budget was reached. Sessions are no longer started by hand
 * (docs/breaks-and-sessions.md), so no client shows this. It is still accepted and stored because
 * Macs up to version 12 send it, and its shape is what the overtime pause extends.
 */
export interface SessionBreak {
  enabled: boolean;
  message: string;
  minutes: number;
  rest: boolean;
}

/** Past the daily limit, a pause after every `every_minutes` of further looking. */
export interface OvertimeBreak extends SessionBreak {
  every_minutes: number;
}

/** A pause at a local clock time, such as lunch. Its window is `at` plus `minutes`. */
export interface ScheduledBreak {
  id: string;
  at: string;
  message: string;
  minutes: number;
}

export interface BreakSettings {
  /** Master switch: off means no pause of any kind. */
  enabled: boolean;
  every_minutes: number;
  items: BreakItem[];
  /** The every-few-minutes pause, separately from the others. */
  recurring_enabled: boolean;
  session_break: SessionBreak;
  overtime: OvertimeBreak;
  scheduled: ScheduledBreak[];
}

/** What a client sent. Macs from before the newer kinds send only the first three fields. */
export type BreakSettingsInput = Pick<BreakSettings, "enabled" | "every_minutes" | "items"> &
  Partial<Pick<BreakSettings, "recurring_enabled" | "session_break" | "overtime" | "scheduled">>;

const ID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const CLOCK = /^([01]\d|2[0-3]):[0-5]\d$/;
const MAX_ITEMS = 20;
const MAX_SCHEDULED = 10;
const MAX_MESSAGE = 200;

export const DEFAULT_SESSION_BREAK: SessionBreak = {
  enabled: false,
  message: "Session done. Step away from the screen.",
  minutes: 5,
  rest: true,
};

export const DEFAULT_OVERTIME: OvertimeBreak = {
  enabled: false,
  every_minutes: 25,
  message: "You are past today's limit. Step away.",
  minutes: 5,
  rest: true,
};

export const DEFAULT_BREAKS: BreakSettings = {
  enabled: true,
  every_minutes: 15,
  items: [{ id: "00000000-0000-4000-8000-000000000001", message: "Step away from the screen.", minutes: 5, rest: true }],
  recurring_enabled: true,
  session_break: DEFAULT_SESSION_BREAK,
  overtime: DEFAULT_OVERTIME,
  scheduled: [],
};

function wholeIn(value: unknown, min: number, max: number): value is number {
  return Number.isInteger(value) && (value as number) >= min && (value as number) <= max;
}

function message(value: unknown): string | null {
  const text = typeof value === "string" ? value.trim() : "";
  return text.length === 0 || text.length > MAX_MESSAGE ? null : text;
}

function parseSessionBreak(value: unknown): SessionBreak | null {
  if (value === null || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  const text = message(record.message);
  if (typeof record.enabled !== "boolean" || text === null) return null;
  if (!wholeIn(record.minutes, 1, 180) || typeof record.rest !== "boolean") return null;
  return { enabled: record.enabled, message: text, minutes: record.minutes as number, rest: record.rest };
}

function parseOvertime(value: unknown): OvertimeBreak | null {
  const base = parseSessionBreak(value);
  if (!base) return null;
  const every = (value as Record<string, unknown>).every_minutes;
  if (!wholeIn(every, 1, 240)) return null;
  return { enabled: base.enabled, every_minutes: every as number, message: base.message, minutes: base.minutes, rest: base.rest };
}

function parseScheduled(value: unknown): ScheduledBreak[] | null {
  if (!Array.isArray(value) || value.length > MAX_SCHEDULED) return null;
  const entries: ScheduledBreak[] = [];
  for (const raw of value) {
    if (raw === null || typeof raw !== "object") return null;
    const entry = raw as Record<string, unknown>;
    const text = message(entry.message);
    if (typeof entry.id !== "string" || !ID.test(entry.id)) return null;
    if (typeof entry.at !== "string" || !CLOCK.test(entry.at)) return null;
    if (text === null || !wholeIn(entry.minutes, 1, 180)) return null;
    entries.push({ id: entry.id, at: entry.at, message: text, minutes: entry.minutes as number });
  }
  return entries;
}

export function parseBreakSettings(value: unknown): { ok: true; settings: BreakSettingsInput } | { ok: false; error: string } {
  if (value === null || typeof value !== "object") return { ok: false, error: "bad_breaks" };
  const record = value as Record<string, unknown>;
  if (typeof record.enabled !== "boolean") return { ok: false, error: "bad_enabled" };
  if (!wholeIn(record.every_minutes, 1, 240)) return { ok: false, error: "bad_every_minutes" };
  if (!Array.isArray(record.items) || record.items.length === 0 || record.items.length > MAX_ITEMS) {
    return { ok: false, error: "bad_items" };
  }
  const items: BreakItem[] = [];
  for (const raw of record.items) {
    if (raw === null || typeof raw !== "object") return { ok: false, error: "bad_items" };
    const item = raw as Record<string, unknown>;
    const message = typeof item.message === "string" ? item.message.trim() : "";
    if (typeof item.id !== "string" || !ID.test(item.id)) return { ok: false, error: "bad_item_id" };
    if (message.length === 0 || message.length > MAX_MESSAGE) return { ok: false, error: "bad_item_message" };
    if (!wholeIn(item.minutes, 1, 180)) return { ok: false, error: "bad_item_minutes" };
    if (typeof item.rest !== "boolean") return { ok: false, error: "bad_item_rest" };
    items.push({ id: item.id, message, minutes: item.minutes as number, rest: item.rest });
  }
  const settings: BreakSettingsInput = { enabled: record.enabled, every_minutes: record.every_minutes as number, items };
  if (record.recurring_enabled !== undefined) {
    if (typeof record.recurring_enabled !== "boolean") return { ok: false, error: "bad_recurring_enabled" };
    settings.recurring_enabled = record.recurring_enabled;
  }
  if (record.session_break !== undefined) {
    const session = parseSessionBreak(record.session_break);
    if (!session) return { ok: false, error: "bad_session_break" };
    settings.session_break = session;
  }
  if (record.overtime !== undefined) {
    const overtime = parseOvertime(record.overtime);
    if (!overtime) return { ok: false, error: "bad_overtime" };
    settings.overtime = overtime;
  }
  if (record.scheduled !== undefined) {
    const scheduled = parseScheduled(record.scheduled);
    if (!scheduled) return { ok: false, error: "bad_scheduled" };
    settings.scheduled = scheduled;
  }
  return { ok: true, settings };
}

/** A stored record from before the newer kinds existed reads with their defaults. */
export function withBreakDefaults(stored: BreakSettingsInput): BreakSettings {
  return {
    enabled: stored.enabled,
    every_minutes: stored.every_minutes,
    items: stored.items,
    recurring_enabled: stored.recurring_enabled ?? DEFAULT_BREAKS.recurring_enabled,
    session_break: stored.session_break ?? DEFAULT_SESSION_BREAK,
    overtime: stored.overtime ?? DEFAULT_OVERTIME,
    scheduled: stored.scheduled ?? [],
  };
}

/** A field the client left out keeps its stored value, so an older Mac cannot erase the newer kinds. */
export function mergeBreakSettings(stored: BreakSettings, input: BreakSettingsInput): BreakSettings {
  return {
    enabled: input.enabled,
    every_minutes: input.every_minutes,
    items: input.items,
    recurring_enabled: input.recurring_enabled ?? stored.recurring_enabled,
    session_break: input.session_break ?? stored.session_break,
    overtime: input.overtime ?? stored.overtime,
    scheduled: input.scheduled ?? stored.scheduled,
  };
}
