/** Civil day bounds in an IANA timezone. Workers run in UTC. */

function part(parts: Intl.DateTimeFormatPart[], type: Intl.DateTimeFormatPartTypes): number {
  const value = parts.find((item) => item.type === type)?.value;
  if (value === undefined) {
    throw new Error(`missing date part ${type}`);
  }
  return Number(value);
}

/** Milliseconds to add to a UTC instant to get the zone's wall clock, encoded as UTC. */
export function zoneOffsetMs(utcMs: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(new Date(utcMs));
  let hour = part(parts, "hour");
  if (hour === 24) hour = 0;
  const asUtc = Date.UTC(part(parts, "year"), part(parts, "month") - 1, part(parts, "day"), hour, part(parts, "minute"), part(parts, "second"));
  return asUtc - utcMs;
}

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone }).format(0);
    return true;
  } catch {
    return false;
  }
}

export function dayKey(utcMs: number, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(utcMs));
  const year = String(part(parts, "year")).padStart(4, "0");
  const month = String(part(parts, "month")).padStart(2, "0");
  const day = String(part(parts, "day")).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/** UTC instant of local midnight at the start of `day` (`YYYY-MM-DD`). */
export function startOfZonedDay(day: string, timeZone: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!match) throw new Error("bad day");
  const year = Number(match[1]);
  const month = Number(match[2]);
  const dayOfMonth = Number(match[3]);
  const utcMidnight = Date.UTC(year, month - 1, dayOfMonth, 0, 0, 0);
  const first = zoneOffsetMs(utcMidnight, timeZone);
  let start = utcMidnight - first;
  const second = zoneOffsetMs(start, timeZone);
  if (second !== first) start = utcMidnight - second;
  return start;
}

export function dayWindow(day: string, timeZone: string): { startMs: number; endMs: number } {
  const startMs = startOfZonedDay(day, timeZone);
  const nextKey = dayKey(startMs + 26 * 60 * 60 * 1000, timeZone);
  const endMs = startOfZonedDay(nextKey, timeZone);
  if (!(endMs > startMs)) throw new Error("bad day window");
  return { startMs, endMs };
}

export function daysTouched(startMs: number, endMs: number, timeZone: string): string[] {
  const days: string[] = [];
  let cursor = startMs;
  const last = Math.max(startMs, endMs - 1);
  while (cursor <= last) {
    const key = dayKey(cursor, timeZone);
    days.push(key);
    const window = dayWindow(key, timeZone);
    cursor = window.endMs;
    if (days.length > 4) break;
  }
  return days;
}
