import { DurableObject } from "cloudflare:workers";
import { DEFAULT_BREAKS, mergeBreakSettings, withBreakDefaults, type BreakSettings, type BreakSettingsInput } from "./breaks";
import { limitCutoff, standingLimit } from "./ceiling";
import { dayKey, dayWindow, daysTouched } from "./day";
import { creditDay, type DayCredit, type RawInterval } from "./merge";
import { base64url, sha256Hex } from "./password";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const APP_KEY = /^[A-Za-z0-9._-]{1,200}$/;
const MAX_DURATION_MS = 305_000;
const MAX_CLOCK_OFFSET_MS = 900_000;
const SESSION_MS = 30 * 24 * 60 * 60 * 1000;

export interface IntervalInput {
  interval_id: string;
  start_wall_ms: number;
  end_wall_ms: number;
  duration_ms: number;
  app_key: string;
  app_display_name?: string | null;
  source: string;
  browser_family?: string | null;
  attendance: string;
  input_marks: Array<{ at_ms: number; input_ms: number }>;
  media_bout_start_ms?: number | null;
  site_unknown?: number;
  audible?: number | null;
  boot_id?: string | null;
}

export interface UploadResult {
  status: number;
  error?: string;
  batch_id?: string;
  accepted?: number;
  duplicate_intervals?: number;
  duplicate_batch?: boolean;
  merge_version?: number;
  clock_offset_ms?: number;
  server_received_at_ms?: number;
  days_recomputed?: string[];
}

export interface StatsDay {
  day: string;
  credited_ms: number;
  ceiling_ms: number | null;
  over: boolean | null;
  unattributed_ms: number;
  apps: Array<{ appKey: string; creditedMs: number }>;
  devices: Array<{ deviceId: string; rawMs: number; creditedMs: number }>;
}

/** Every device on the account, oldest first, so the web app can give each a stable color. */
export interface DeviceInfo {
  device_id: string;
  display_name: string;
  platform: string;
  created_at_ms: number;
  last_upload_at_ms: number | null;
  revoked: boolean;
}

export type StatsResult =
  | { error: string; status: number }
  | { timezone: string; username: string; days: StatsDay[]; device_info: DeviceInfo[] };

export interface DayDetail {
  day: string;
  timezone: string;
  start_ms: number;
  end_ms: number;
  credited_ms: number;
  ceiling_ms: number | null;
  over: boolean | null;
  apps: Array<{ appKey: string; creditedMs: number }>;
  devices: Array<{ deviceId: string; rawMs: number; creditedMs: number; apps: Array<{ appKey: string; creditedMs: number }> }>;
  segments: Array<{ device_id: string; app_key: string; start_ms: number; end_ms: number }>;
  device_info: DeviceInfo[];
}

export type DayDetailResult = { error: string; status: number } | DayDetail;

export interface UploadInput {
  deviceToken: string;
  pathDeviceId: string;
  bodySha256: string;
  receivedAtMs: number;
  batchId: string;
  deviceWallAtSend: number;
  uploadPeriodMs: number;
  intervals: IntervalInput[];
}

interface DeviceRow {
  device_id: string;
  platform: string;
  role: string;
  revoked_at_ms: number | null;
  [column: string]: SqlStorageValue;
}

interface StoredInterval {
  device_id: string;
  start_wall_ms: number;
  end_wall_ms: number;
  app_key: string;
  input_marks_json: string;
  [column: string]: SqlStorageValue;
}

function latestInputMs(marks: Array<{ at_ms: number; input_ms: number }>, startMs: number): number {
  let latest = startMs;
  for (const mark of marks) {
    if (mark.input_ms >= latest) latest = mark.input_ms;
  }
  return latest;
}

function validateInterval(interval: IntervalInput): string | null {
  if (!UUID.test(interval.interval_id)) return "bad_interval_id";
  if (interval.source !== "os-window") return "bad_source";
  if (interval.attendance !== "input") return "bad_attendance";
  if (!APP_KEY.test(interval.app_key)) return "bad_app_key";
  if (!Number.isInteger(interval.duration_ms) || interval.duration_ms <= 0 || interval.duration_ms > MAX_DURATION_MS) return "bad_duration";
  if (interval.end_wall_ms !== interval.start_wall_ms + interval.duration_ms) return "bad_span";
  if (!Array.isArray(interval.input_marks) || interval.input_marks.length === 0) return "bad_marks";
  let previous = -1;
  for (const mark of interval.input_marks) {
    if (!Number.isInteger(mark.at_ms) || !Number.isInteger(mark.input_ms)) return "bad_marks";
    if (mark.at_ms < interval.start_wall_ms || mark.at_ms > interval.end_wall_ms) return "bad_marks";
    if (mark.input_ms > mark.at_ms) return "bad_marks";
    if (mark.at_ms <= previous) return "bad_marks";
    previous = mark.at_ms;
  }
  return null;
}

export class UserAccount extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const statements = [
        `CREATE TABLE IF NOT EXISTS user (
          user_id TEXT PRIMARY KEY,
          username TEXT NOT NULL,
          timezone TEXT NOT NULL,
          idle_threshold_ms INTEGER NOT NULL DEFAULT 120000,
          merge_version INTEGER NOT NULL DEFAULT 0,
          created_at_ms INTEGER NOT NULL
        )`,
        `CREATE TABLE IF NOT EXISTS session (
          session_id TEXT PRIMARY KEY,
          token_hash TEXT NOT NULL UNIQUE,
          created_at_ms INTEGER NOT NULL,
          expires_at_ms INTEGER NOT NULL,
          revoked_at_ms INTEGER
        )`,
        `CREATE TABLE IF NOT EXISTS device (
          device_id TEXT PRIMARY KEY,
          token_hash TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          platform TEXT NOT NULL,
          role TEXT NOT NULL,
          created_at_ms INTEGER NOT NULL,
          revoked_at_ms INTEGER,
          last_upload_at_ms INTEGER,
          clock_offset_ms INTEGER
        )`,
        `CREATE TABLE IF NOT EXISTS batch (
          device_id TEXT NOT NULL,
          batch_id TEXT NOT NULL,
          body_sha256 TEXT NOT NULL,
          received_at_ms INTEGER NOT NULL,
          clock_offset_ms INTEGER NOT NULL,
          ack_json TEXT NOT NULL,
          PRIMARY KEY (device_id, batch_id)
        )`,
        `CREATE TABLE IF NOT EXISTS interval (
          device_id TEXT NOT NULL,
          interval_id TEXT NOT NULL,
          batch_id TEXT NOT NULL,
          start_wall_ms INTEGER NOT NULL,
          end_wall_ms INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL,
          app_key TEXT NOT NULL,
          app_display_name TEXT,
          source TEXT NOT NULL,
          attendance TEXT NOT NULL,
          input_marks_json TEXT NOT NULL,
          clock_offset_ms INTEGER NOT NULL,
          boot_id TEXT,
          inserted_at_ms INTEGER NOT NULL,
          PRIMARY KEY (device_id, interval_id)
        )`,
        `CREATE INDEX IF NOT EXISTS interval_span ON interval (start_wall_ms, end_wall_ms)`,
        `CREATE TABLE IF NOT EXISTS rollup_day (
          day TEXT PRIMARY KEY,
          credited_ms INTEGER NOT NULL,
          unattributed_ms INTEGER NOT NULL,
          ceiling_ms INTEGER,
          over INTEGER,
          apps_json TEXT NOT NULL,
          devices_json TEXT NOT NULL,
          computed_at_ms INTEGER NOT NULL
        )`,
        `CREATE TABLE IF NOT EXISTS budget_version (
          budget_id TEXT PRIMARY KEY,
          scope TEXT NOT NULL,
          period TEXT NOT NULL,
          limit_ms INTEGER NOT NULL,
          effective_at_ms INTEGER NOT NULL,
          created_at_ms INTEGER NOT NULL
        )`,
        `CREATE TABLE IF NOT EXISTS break_settings (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          settings_json TEXT NOT NULL,
          updated_at_ms INTEGER NOT NULL
        )`,
      ];
      for (const statement of statements) this.ctx.storage.sql.exec(statement);
    });
  }

  async init(input: { userId: string; username: string; timezone: string; now: number }): Promise<void> {
    const existing = this.ctx.storage.sql.exec<{ user_id: string }>("SELECT user_id FROM user").toArray()[0];
    if (existing) return;
    this.ctx.storage.sql.exec(
      "INSERT INTO user (user_id, username, timezone, idle_threshold_ms, merge_version, created_at_ms) VALUES (?, ?, ?, 120000, 0, ?)",
      input.userId,
      input.username,
      input.timezone,
      input.now,
    );
  }

  async createSession(now: number): Promise<{ token: string; expiresAtMs: number; username: string; timezone: string }> {
    const user = this.requireUser();
    const token = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const hash = await sha256Hex(token);
    const expiresAtMs = now + SESSION_MS;
    this.ctx.storage.sql.exec(
      "INSERT INTO session (session_id, token_hash, created_at_ms, expires_at_ms, revoked_at_ms) VALUES (?, ?, ?, ?, NULL)",
      crypto.randomUUID(),
      hash,
      now,
      expiresAtMs,
    );
    return { token, expiresAtMs, username: user.username, timezone: user.timezone };
  }

  async enrollDevice(input: { sessionToken: string; now: number; deviceId: string; displayName: string; platform: string; role: string }): Promise<{ ok: true; deviceToken: string } | { ok: false; error: string }> {
    const session = await this.sessionFor(input.sessionToken, input.now);
    if (!session) return { ok: false, error: "bad_token" };
    if (input.platform !== "macos" || input.role !== "collector") return { ok: false, error: "not_collector" };
    if (!UUID.test(input.deviceId)) return { ok: false, error: "bad_device_id" };
    const name = input.displayName.trim().slice(0, 80);
    if (!name) return { ok: false, error: "bad_display_name" };
    const deviceToken = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const hash = await sha256Hex(deviceToken);
    const existing = this.ctx.storage.sql.exec<{ device_id: string }>("SELECT device_id FROM device WHERE device_id = ?", input.deviceId).toArray()[0];
    if (existing) {
      this.ctx.storage.sql.exec(
        "UPDATE device SET token_hash = ?, display_name = ?, platform = ?, role = ?, revoked_at_ms = NULL WHERE device_id = ?",
        hash,
        name,
        input.platform,
        input.role,
        input.deviceId,
      );
    } else {
      this.ctx.storage.sql.exec(
        "INSERT INTO device (device_id, token_hash, display_name, platform, role, created_at_ms, revoked_at_ms, last_upload_at_ms, clock_offset_ms) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL)",
        input.deviceId,
        hash,
        name,
        input.platform,
        input.role,
        input.now,
      );
    }
    return { ok: true, deviceToken };
  }

  async upload(input: UploadInput): Promise<UploadResult> {
    const device = await this.deviceFor(input.deviceToken);
    if (!device) return { error: "bad_token", status: 401 };
    if (device.revoked_at_ms !== null) return { error: "revoked", status: 401 };
    if (device.platform !== "macos" || device.role !== "collector") return { error: "not_collector", status: 403 };
    if (input.pathDeviceId !== device.device_id) return { error: "bad_device_id", status: 422 };
    return this.applyUpload(device.device_id, input);
  }

  async stats(input: { token: string; now: number; from: string | null; to: string | null }): Promise<StatsResult | null> {
    const allowed = (await this.sessionFor(input.token, input.now)) || (await this.deviceFor(input.token));
    if (!allowed) return null;
    const user = this.requireUser();
    const today = dayKey(input.now, user.timezone);
    const from = input.from ?? today;
    const to = input.to ?? today;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || from > to) {
      return { error: "bad_range", status: 422 };
    }
    const days = [];
    let cursor = from;
    while (cursor <= to && days.length < 31) {
      days.push(this.readDay(cursor, user.timezone, input.now));
      cursor = dayKey(dayWindow(cursor, user.timezone).endMs + 60_000, user.timezone);
      if (cursor === days[days.length - 1]?.day) break;
    }
    return { timezone: user.timezone, username: user.username, days, device_info: this.deviceInfo() };
  }

  // One day computed fresh from the raw intervals, with the credited timeline.
  async dayDetail(input: { token: string; now: number; day: string }): Promise<DayDetailResult | null> {
    const allowed = (await this.sessionFor(input.token, input.now)) || (await this.deviceFor(input.token));
    if (!allowed) return null;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(input.day)) return { error: "bad_day", status: 422 };
    const user = this.requireUser();
    let window: { startMs: number; endMs: number };
    try {
      window = dayWindow(input.day, user.timezone);
    } catch {
      return { error: "bad_day", status: 422 };
    }
    // Date.UTC rolls 2026-13-45 into a real date; only a day that round-trips is valid.
    if (dayKey(window.startMs, user.timezone) !== input.day) return { error: "bad_day", status: 422 };
    const credit = this.creditFor(window);
    const ceiling = this.ceilingMs(limitCutoff(window.endMs, input.now));
    return {
      day: input.day,
      timezone: user.timezone,
      start_ms: window.startMs,
      end_ms: window.endMs,
      credited_ms: credit.creditedMs,
      ceiling_ms: ceiling,
      over: ceiling === null ? null : credit.creditedMs > ceiling,
      apps: credit.apps,
      devices: credit.devices.map((device) => ({
        ...device,
        apps: credit.deviceApps
          .filter((pair) => pair.deviceId === device.deviceId)
          .map((pair) => ({ appKey: pair.appKey, creditedMs: pair.creditedMs })),
      })),
      segments: credit.segments.map((segment) => ({
        device_id: segment.deviceId,
        app_key: segment.appKey,
        start_ms: segment.startMs,
        end_ms: segment.endMs,
      })),
      device_info: this.deviceInfo(),
    };
  }

  // Cheap enough for a Mac to ask every few seconds: it says when breaks last changed
  // and what limit governs right now, so the Mac fetches breaks only when they moved.
  async settings(input: { token: string; now: number }): Promise<{
    timezone: string;
    idleThresholdMs: number;
    username: string;
    limitMs: number | null;
    breaksUpdatedAtMs: number;
  } | null> {
    const allowed = (await this.sessionFor(input.token, input.now)) || (await this.deviceFor(input.token));
    if (!allowed) return null;
    const user = this.requireUser();
    const breaks = this.ctx.storage.sql
      .exec<{ updated_at_ms: number }>("SELECT updated_at_ms FROM break_settings WHERE id = 1")
      .toArray()[0];
    return {
      timezone: user.timezone,
      idleThresholdMs: user.idle_threshold_ms,
      username: user.username,
      limitMs: this.ceilingMs(input.now),
      breaksUpdatedAtMs: breaks?.updated_at_ms ?? 0,
    };
  }

  // updated_at_ms is 0 until someone saves, so a Mac knows to upload its own copy.
  async breaks(input: { token: string; now: number }): Promise<(BreakSettings & { updated_at_ms: number }) | null> {
    const allowed = (await this.sessionFor(input.token, input.now)) || (await this.deviceFor(input.token));
    if (!allowed) return null;
    const row = this.ctx.storage.sql
      .exec<{ settings_json: string; updated_at_ms: number }>("SELECT settings_json, updated_at_ms FROM break_settings WHERE id = 1")
      .toArray()[0];
    if (!row) return { ...DEFAULT_BREAKS, updated_at_ms: 0 };
    return { ...this.storedBreaks(row.settings_json), updated_at_ms: row.updated_at_ms };
  }

  async setBreaks(input: { sessionToken: string; settings: BreakSettingsInput; now: number }): Promise<(BreakSettings & { updated_at_ms: number }) | null> {
    const session = await this.sessionFor(input.sessionToken, input.now);
    if (!session) return null;
    const row = this.ctx.storage.sql
      .exec<{ settings_json: string }>("SELECT settings_json FROM break_settings WHERE id = 1")
      .toArray()[0];
    const stored = row ? this.storedBreaks(row.settings_json) : DEFAULT_BREAKS;
    const settings = mergeBreakSettings(stored, input.settings);
    this.ctx.storage.sql.exec(
      "INSERT INTO break_settings (id, settings_json, updated_at_ms) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET settings_json = excluded.settings_json, updated_at_ms = excluded.updated_at_ms",
      JSON.stringify(settings),
      input.now,
    );
    return { ...settings, updated_at_ms: input.now };
  }

  private storedBreaks(json: string): BreakSettings {
    return withBreakDefaults(JSON.parse(json) as BreakSettingsInput);
  }

  async setOwnLimit(input: { sessionToken: string; limitMs: number; now: number }): Promise<{ error: "bad_token" } | { budgetId: string; limitMs: number; effectiveAtMs: number }> {
    const session = await this.sessionFor(input.sessionToken, input.now);
    if (!session) return { error: "bad_token" };
    return this.setLimit({ limitMs: input.limitMs, now: input.now });
  }

  async setLimit(input: { limitMs: number; now: number }): Promise<{ budgetId: string; limitMs: number; effectiveAtMs: number }> {
    if (!Number.isInteger(input.limitMs) || input.limitMs < 0) {
      throw new Error("bad_limit");
    }
    // effective_at is now: today uses the new value, and it stands until the next change.
    const budgetId = crypto.randomUUID();
    this.ctx.storage.sql.exec(
      "INSERT INTO budget_version (budget_id, scope, period, limit_ms, effective_at_ms, created_at_ms) VALUES (?, 'overall', 'day', ?, ?, ?)",
      budgetId,
      input.limitMs,
      input.now,
      input.now,
    );
    const user = this.requireUser();
    const today = dayKey(input.now, user.timezone);
    this.rebuildDay(today, user.timezone, input.now);
    return { budgetId, limitMs: input.limitMs, effectiveAtMs: input.now };
  }

  // Day rollups are cut on local midnights, so every stored day is rebuilt in the new zone.
  async setTimezone(input: { timezone: string; now: number }): Promise<{ timezone: string; daysRebuilt: number }> {
    this.ctx.storage.sql.exec("UPDATE user SET timezone = ?", input.timezone);
    this.ctx.storage.sql.exec("DELETE FROM rollup_day");
    const span = this.ctx.storage.sql
      .exec<{ first: number | null; last: number | null }>("SELECT MIN(start_wall_ms) AS first, MAX(end_wall_ms) AS last FROM interval")
      .toArray()[0];
    let daysRebuilt = 0;
    if (span?.first != null && span.last != null) {
      let cursor = span.first;
      while (cursor < span.last) {
        const day = dayKey(cursor, input.timezone);
        this.rebuildDay(day, input.timezone, input.now);
        daysRebuilt += 1;
        cursor = dayWindow(day, input.timezone).endMs;
      }
    }
    return { timezone: input.timezone, daysRebuilt };
  }

  async revokeSessions(now: number): Promise<void> {
    this.ctx.storage.sql.exec("UPDATE session SET revoked_at_ms = ? WHERE revoked_at_ms IS NULL", now);
  }

  async endSession(input: { token: string; now: number }): Promise<void> {
    this.ctx.storage.sql.exec(
      "UPDATE session SET revoked_at_ms = ? WHERE token_hash = ? AND revoked_at_ms IS NULL",
      input.now,
      await sha256Hex(input.token),
    );
  }

  private requireUser(): { user_id: string; username: string; timezone: string; idle_threshold_ms: number } {
    const user = this.ctx.storage.sql
      .exec<{ user_id: string; username: string; timezone: string; idle_threshold_ms: number }>("SELECT user_id, username, timezone, idle_threshold_ms FROM user")
      .toArray()[0];
    if (!user) throw new Error("user_missing");
    return user;
  }

  private async sessionFor(token: string, now: number): Promise<{ session_id: string } | null> {
    const hash = await sha256Hex(token);
    const row = this.ctx.storage.sql
      .exec<{ session_id: string; expires_at_ms: number; revoked_at_ms: number | null }>("SELECT session_id, expires_at_ms, revoked_at_ms FROM session WHERE token_hash = ?", hash)
      .toArray()[0];
    if (!row || row.revoked_at_ms !== null || row.expires_at_ms <= now) return null;
    return { session_id: row.session_id };
  }

  private async deviceFor(token: string): Promise<DeviceRow | null> {
    const hash = await sha256Hex(token);
    return (
      this.ctx.storage.sql
        .exec<DeviceRow>("SELECT device_id, platform, role, revoked_at_ms FROM device WHERE token_hash = ?", hash)
        .toArray()[0] ?? null
    );
  }

  private applyUpload(deviceId: string, input: UploadInput): UploadResult {
    if (!UUID.test(input.batchId)) return { error: "bad_batch_id", status: 422 };
    if (input.intervals.length === 0 || input.intervals.length > 200) return { error: "bad_batch", status: 422 };
    if (input.uploadPeriodMs !== 300_000 && input.uploadPeriodMs !== 900_000) return { error: "bad_upload_period", status: 422 };
    const clockOffsetMs = input.receivedAtMs - input.deviceWallAtSend;
    if (Math.abs(clockOffsetMs) > MAX_CLOCK_OFFSET_MS) {
      return { error: "clock_offset", status: 422, clock_offset_ms: clockOffsetMs, server_received_at_ms: input.receivedAtMs };
    }
    const prior = this.ctx.storage.sql
      .exec<{ body_sha256: string; ack_json: string }>("SELECT body_sha256, ack_json FROM batch WHERE device_id = ? AND batch_id = ?", deviceId, input.batchId)
      .toArray()[0];
    if (prior) {
      if (prior.body_sha256 !== input.bodySha256) return { error: "batch_mismatch", status: 409 };
      const ack = JSON.parse(prior.ack_json) as UploadResult;
      return { ...ack, duplicate_batch: true, status: 200 };
    }
    for (const interval of input.intervals) {
      const problem = validateInterval(interval);
      if (problem) return { error: problem, status: 422 };
    }
    const user = this.requireUser();
    let accepted = 0;
    let duplicates = 0;
    const inserted: IntervalInput[] = [];
    for (const interval of input.intervals) {
      const already = this.ctx.storage.sql
        .exec<{ interval_id: string }>("SELECT interval_id FROM interval WHERE device_id = ? AND interval_id = ?", deviceId, interval.interval_id)
        .toArray()[0];
      if (already) {
        duplicates += 1;
        continue;
      }
      this.ctx.storage.sql.exec(
        `INSERT INTO interval (
          device_id, interval_id, batch_id, start_wall_ms, end_wall_ms, duration_ms, app_key, app_display_name,
          source, attendance, input_marks_json, clock_offset_ms, boot_id, inserted_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        deviceId,
        interval.interval_id,
        input.batchId,
        interval.start_wall_ms,
        interval.end_wall_ms,
        interval.duration_ms,
        interval.app_key,
        interval.app_display_name ?? null,
        interval.source,
        interval.attendance,
        JSON.stringify(interval.input_marks),
        clockOffsetMs,
        interval.boot_id ?? null,
        input.receivedAtMs,
      );
      accepted += 1;
      inserted.push(interval);
    }
    const dirty = new Set<string>();
    for (const interval of inserted) {
      for (const day of daysTouched(interval.start_wall_ms, interval.end_wall_ms, user.timezone)) dirty.add(day);
    }
    for (const day of dirty) this.rebuildDay(day, user.timezone, input.receivedAtMs);
    this.ctx.storage.sql.exec("UPDATE user SET merge_version = merge_version + 1 WHERE user_id = ?", user.user_id);
    this.ctx.storage.sql.exec(
      "UPDATE device SET last_upload_at_ms = ?, clock_offset_ms = ? WHERE device_id = ?",
      input.receivedAtMs,
      clockOffsetMs,
      deviceId,
    );
    const version = this.ctx.storage.sql.exec<{ merge_version: number }>("SELECT merge_version FROM user").toArray()[0]?.merge_version ?? 0;
    const ack = {
      batch_id: input.batchId,
      accepted,
      duplicate_intervals: duplicates,
      duplicate_batch: false,
      merge_version: version,
      clock_offset_ms: clockOffsetMs,
      server_received_at_ms: input.receivedAtMs,
      days_recomputed: [...dirty].sort(),
    };
    this.ctx.storage.sql.exec(
      "INSERT INTO batch (device_id, batch_id, body_sha256, received_at_ms, clock_offset_ms, ack_json) VALUES (?, ?, ?, ?, ?, ?)",
      deviceId,
      input.batchId,
      input.bodySha256,
      input.receivedAtMs,
      clockOffsetMs,
      JSON.stringify(ack),
    );
    return { ...ack, status: 200 };
  }

  private ceilingMs(cutoffMs: number): number | null {
    const rows = this.ctx.storage.sql
      .exec<{ limit_ms: number; effective_at_ms: number }>(
        "SELECT limit_ms, effective_at_ms FROM budget_version WHERE scope = 'overall'",
      )
      .toArray();
    return standingLimit(
      rows.map((row) => ({ limitMs: row.limit_ms, effectiveAtMs: row.effective_at_ms })),
      cutoffMs,
    );
  }

  private deviceInfo(): DeviceInfo[] {
    return this.ctx.storage.sql
      .exec<{
        device_id: string;
        display_name: string;
        platform: string;
        created_at_ms: number;
        last_upload_at_ms: number | null;
        revoked_at_ms: number | null;
      }>("SELECT device_id, display_name, platform, created_at_ms, last_upload_at_ms, revoked_at_ms FROM device ORDER BY created_at_ms, device_id")
      .toArray()
      .map((row) => ({
        device_id: row.device_id,
        display_name: row.display_name,
        platform: row.platform,
        created_at_ms: row.created_at_ms,
        last_upload_at_ms: row.last_upload_at_ms,
        revoked: row.revoked_at_ms !== null,
      }));
  }

  private creditFor(window: { startMs: number; endMs: number }): DayCredit {
    const rows = this.ctx.storage.sql
      .exec<StoredInterval>(
        "SELECT device_id, start_wall_ms, end_wall_ms, app_key, input_marks_json FROM interval WHERE end_wall_ms > ? AND start_wall_ms < ?",
        window.startMs,
        window.endMs,
      )
      .toArray();
    const raw: RawInterval[] = rows.map((row) => {
      const marks = JSON.parse(row.input_marks_json) as Array<{ at_ms: number; input_ms: number }>;
      return {
        deviceId: row.device_id,
        appKey: row.app_key,
        startMs: row.start_wall_ms,
        endMs: row.end_wall_ms,
        inputMs: latestInputMs(marks, row.start_wall_ms),
      };
    });
    return creditDay(raw, window.startMs, window.endMs);
  }

  private rebuildDay(day: string, timeZone: string, now: number): void {
    const window = dayWindow(day, timeZone);
    const credit = this.creditFor(window);
    const cutoff = limitCutoff(window.endMs, now);
    const ceiling = this.ceilingMs(cutoff);
    const over = ceiling === null ? null : credit.creditedMs > ceiling ? 1 : 0;
    this.ctx.storage.sql.exec("DELETE FROM rollup_day WHERE day = ?", day);
    this.ctx.storage.sql.exec(
      "INSERT INTO rollup_day (day, credited_ms, unattributed_ms, ceiling_ms, over, apps_json, devices_json, computed_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      day,
      credit.creditedMs,
      credit.unattributedMs,
      ceiling,
      over,
      JSON.stringify(credit.apps),
      JSON.stringify(credit.devices),
      now,
    );
  }

  private readDay(day: string, timeZone: string, now: number): StatsDay {
    const stored = this.ctx.storage.sql
      .exec<{
        credited_ms: number;
        unattributed_ms: number;
        ceiling_ms: number | null;
        over: number | null;
        apps_json: string;
        devices_json: string;
      }>("SELECT credited_ms, unattributed_ms, ceiling_ms, over, apps_json, devices_json FROM rollup_day WHERE day = ?", day)
      .toArray()[0];
    const window = dayWindow(day, timeZone);
    const cutoff = limitCutoff(window.endMs, now);
    const ceiling = this.ceilingMs(cutoff);
    if (!stored) {
      return {
        day,
        credited_ms: 0,
        ceiling_ms: ceiling,
        over: ceiling === null ? null : false,
        unattributed_ms: 0,
        apps: [],
        devices: [],
      };
    }
    const credited = stored.credited_ms;
    return {
      day,
      credited_ms: credited,
      ceiling_ms: ceiling,
      over: ceiling === null ? null : credited > ceiling,
      unattributed_ms: stored.unattributed_ms,
      apps: JSON.parse(stored.apps_json) as StatsDay["apps"],
      devices: JSON.parse(stored.devices_json) as StatsDay["devices"],
    };
  }
}
