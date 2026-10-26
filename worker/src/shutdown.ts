// Shutdowns asked for from the web, kept in the account's own tables. Only a login session reaches
// these, never a device token, so a token taken from one Mac cannot shut down another.

export interface ShutdownState {
  command_id: string;
  state: "pending" | "cancelled" | "delivered" | "failed";
  requested_at_ms: number;
  delivered_at_ms: number | null;
  result: string | null;
}

export type Refusal = { error: string; status: number };

/** Every device must be a signed-in Mac on this account, or nothing is done to any of them. */
export function refuseTargets(sql: SqlStorage, deviceIds: string[]): Refusal | null {
  for (const deviceId of deviceIds) {
    const device = sql
      .exec<{ platform: string; revoked_at_ms: number | null }>("SELECT platform, revoked_at_ms FROM device WHERE device_id = ?", deviceId)
      .toArray()[0];
    if (!device) return { error: "no_such_device", status: 404 };
    if (device.revoked_at_ms !== null) return { error: "revoked", status: 409 };
    if (device.platform !== "macos") return { error: "not_supported", status: 422 };
  }
  return null;
}

/** Asks each Mac to shut down the next time it checks in. One already pending is left as it is. */
export function askShutdowns(sql: SqlStorage, deviceIds: string[], now: number): void {
  for (const deviceId of deviceIds) {
    if (latestShutdown(sql, deviceId)?.state === "pending") continue;
    sql.exec(
      "INSERT INTO device_command (command_id, device_id, kind, requested_at_ms, cancelled_at_ms, delivered_at_ms, result) VALUES (?, ?, 'shutdown', ?, NULL, NULL, NULL)",
      crypto.randomUUID(),
      deviceId,
      now,
    );
  }
}

/** Withdraws a shutdown the Mac has not picked up yet. One already delivered cannot be called back. */
export function withdrawShutdown(sql: SqlStorage, deviceId: string, now: number): void {
  sql.exec(
    "UPDATE device_command SET cancelled_at_ms = ? WHERE device_id = ? AND kind = 'shutdown' AND cancelled_at_ms IS NULL AND delivered_at_ms IS NULL",
    now,
    deviceId,
  );
}

interface CommandRow {
  device_id: string;
  command_id: string;
  requested_at_ms: number;
  cancelled_at_ms: number | null;
  delivered_at_ms: number | null;
  result: string | null;
  [column: string]: SqlStorageValue;
}

function shutdownState(row: CommandRow): ShutdownState {
  const state: ShutdownState["state"] =
    row.cancelled_at_ms !== null ? "cancelled"
    : row.delivered_at_ms === null ? "pending"
    : row.result?.startsWith("failed:") ? "failed"
    : "delivered";
  return {
    command_id: row.command_id,
    state,
    requested_at_ms: row.requested_at_ms,
    delivered_at_ms: row.delivered_at_ms,
    result: row.result,
  };
}

export function latestShutdown(sql: SqlStorage, deviceId: string): ShutdownState | null {
  const row = sql
    .exec<CommandRow>(
      "SELECT device_id, command_id, requested_at_ms, cancelled_at_ms, delivered_at_ms, result FROM device_command WHERE device_id = ? AND kind = 'shutdown' ORDER BY requested_at_ms DESC, rowid DESC LIMIT 1",
      deviceId,
    )
    .toArray()[0];
  return row ? shutdownState(row) : null;
}

/** The latest shutdown of every device, in one query, for the device list. */
export function latestShutdowns(sql: SqlStorage): Map<string, ShutdownState> {
  const rows = sql
    .exec<CommandRow>(
      `SELECT device_id, command_id, requested_at_ms, cancelled_at_ms, delivered_at_ms, result FROM device_command AS c
       WHERE kind = 'shutdown' AND rowid = (
         SELECT rowid FROM device_command WHERE device_id = c.device_id AND kind = 'shutdown' ORDER BY requested_at_ms DESC, rowid DESC LIMIT 1
       )`,
    )
    .toArray();
  return new Map(rows.map((row) => [row.device_id, shutdownState(row)]));
}
