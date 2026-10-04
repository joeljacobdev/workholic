// Break settings shared by the web app and every Mac on the account.
// Which pause comes next is per Mac and is not stored here.

export interface BreakItem {
  id: string;
  message: string;
  minutes: number;
  rest: boolean;
}

export interface BreakSettings {
  enabled: boolean;
  every_minutes: number;
  items: BreakItem[];
}

const ID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const MAX_ITEMS = 20;
const MAX_MESSAGE = 200;

export const DEFAULT_BREAKS: BreakSettings = {
  enabled: true,
  every_minutes: 15,
  items: [{ id: "00000000-0000-4000-8000-000000000001", message: "Step away from the screen.", minutes: 5, rest: true }],
};

function wholeIn(value: unknown, min: number, max: number): value is number {
  return Number.isInteger(value) && (value as number) >= min && (value as number) <= max;
}

export function parseBreakSettings(value: unknown): { ok: true; settings: BreakSettings } | { ok: false; error: string } {
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
  return { ok: true, settings: { enabled: record.enabled, every_minutes: record.every_minutes as number, items } };
}
