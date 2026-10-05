/** One sealed slice already clipped to the caller's needs. */
export interface RawInterval {
  deviceId: string;
  appKey: string;
  startMs: number;
  endMs: number;
  /** Latest real input on this slice. Media-only slices pass the slice start. */
  inputMs: number;
}

export interface DeviceTotal {
  deviceId: string;
  rawMs: number;
  creditedMs: number;
}

export interface AppTotal {
  appKey: string;
  creditedMs: number;
}

export interface DeviceAppTotal {
  deviceId: string;
  appKey: string;
  creditedMs: number;
}

/** A run of credited time that one device and one app held without a break. */
export interface CreditedSegment {
  deviceId: string;
  appKey: string;
  startMs: number;
  endMs: number;
}

export interface DayCredit {
  creditedMs: number;
  unattributedMs: number;
  apps: AppTotal[];
  devices: DeviceTotal[];
  deviceApps: DeviceAppTotal[];
  segments: CreditedSegment[];
}

interface Clipped extends RawInterval {}

function unionMs(ranges: Array<{ startMs: number; endMs: number }>): number {
  const sorted = [...ranges].sort((a, b) => a.startMs - b.startMs || a.endMs - b.endMs);
  let total = 0;
  let cursor = -1;
  for (const range of sorted) {
    if (range.endMs <= range.startMs) continue;
    if (range.startMs >= cursor) {
      total += range.endMs - range.startMs;
      cursor = range.endMs;
    } else if (range.endMs > cursor) {
      total += range.endMs - cursor;
      cursor = range.endMs;
    }
  }
  return total;
}

function winner(active: Clipped[]): Clipped {
  return active.reduce((best, item) => {
    if (item.inputMs > best.inputMs) return item;
    if (item.inputMs === best.inputMs && item.deviceId > best.deviceId) return item;
    return best;
  });
}

/**
 * Credited time is the union of slices in the half-open day.
 * An overlap goes to the slice with the later real input.
 * A tie goes to the larger device id. One device's own overlap is counted once.
 */
export function creditDay(rows: RawInterval[], dayStart: number, dayEnd: number): DayCredit {
  const clipped: Clipped[] = [];
  for (const row of rows) {
    const startMs = Math.max(row.startMs, dayStart);
    const endMs = Math.min(row.endMs, dayEnd);
    if (endMs <= startMs) continue;
    clipped.push({ ...row, startMs, endMs });
  }

  const points = new Set<number>([dayStart, dayEnd]);
  for (const row of clipped) {
    points.add(row.startMs);
    points.add(row.endMs);
  }
  const axis = [...points].sort((a, b) => a - b);

  const creditedByDevice = new Map<string, number>();
  const creditedByApp = new Map<string, number>();
  const creditedByDeviceApp = new Map<string, DeviceAppTotal>();
  const segments: CreditedSegment[] = [];
  let creditedMs = 0;
  let unattributedMs = 0;

  for (let index = 0; index < axis.length - 1; index += 1) {
    const startMs = axis[index];
    const endMs = axis[index + 1];
    if (endMs <= startMs) continue;
    const active = clipped.filter((row) => row.startMs <= startMs && row.endMs >= endMs);
    if (active.length === 0) continue;
    const chosen = winner(active);
    const duration = endMs - startMs;
    creditedMs += duration;
    creditedByDevice.set(chosen.deviceId, (creditedByDevice.get(chosen.deviceId) ?? 0) + duration);
    creditedByApp.set(chosen.appKey, (creditedByApp.get(chosen.appKey) ?? 0) + duration);
    if (chosen.appKey === "unattributed") unattributedMs += duration;
    const pairKey = `${chosen.deviceId}\u0000${chosen.appKey}`;
    const pair = creditedByDeviceApp.get(pairKey);
    if (pair) pair.creditedMs += duration;
    else creditedByDeviceApp.set(pairKey, { deviceId: chosen.deviceId, appKey: chosen.appKey, creditedMs: duration });
    const last = segments[segments.length - 1];
    if (last && last.endMs === startMs && last.deviceId === chosen.deviceId && last.appKey === chosen.appKey) last.endMs = endMs;
    else segments.push({ deviceId: chosen.deviceId, appKey: chosen.appKey, startMs, endMs });
  }

  const deviceIds = new Set<string>(clipped.map((row) => row.deviceId));
  const devices: DeviceTotal[] = [...deviceIds].sort().map((deviceId) => ({
    deviceId,
    rawMs: unionMs(clipped.filter((row) => row.deviceId === deviceId)),
    creditedMs: creditedByDevice.get(deviceId) ?? 0,
  }));
  const apps: AppTotal[] = [...creditedByApp.entries()]
    .map(([appKey, ms]) => ({ appKey, creditedMs: ms }))
    .sort((a, b) => b.creditedMs - a.creditedMs || a.appKey.localeCompare(b.appKey));

  const deviceApps = [...creditedByDeviceApp.values()].sort(
    (a, b) => a.deviceId.localeCompare(b.deviceId) || b.creditedMs - a.creditedMs || a.appKey.localeCompare(b.appKey),
  );

  return { creditedMs, unattributedMs, apps, devices, deviceApps, segments };
}
