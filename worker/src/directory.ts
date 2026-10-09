import { DurableObject } from "cloudflare:workers";
import { base64ToBytes, bytesToBase64, dummyHash, hashPassword, PBKDF2_ITERATIONS, timingSafeEqual } from "./password";

const USERNAME = /^[a-z][a-z0-9._-]{1,31}$/;

export function normalizeUsername(username: string): string | null {
  const value = username.trim().toLowerCase();
  return USERNAME.test(value) ? value : null;
}

export function passwordAccepted(password: string): boolean {
  return password.length >= 8 && password.length <= 200;
}

interface AccountRow {
  username: string;
  user_id: string;
  password_salt: string;
  password_hash: string;
  iterations: number;
  [column: string]: SqlStorageValue;
}

export class Directory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      for (const statement of [
        `CREATE TABLE IF NOT EXISTS account (
          username TEXT PRIMARY KEY,
          user_id TEXT NOT NULL UNIQUE,
          password_salt TEXT NOT NULL,
          password_hash TEXT NOT NULL,
          iterations INTEGER NOT NULL,
          created_at_ms INTEGER NOT NULL
        )`,
        `CREATE TABLE IF NOT EXISTS token (
          token_hash TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          device_id TEXT,
          expires_at_ms INTEGER
        )`,
      ]) {
        this.ctx.storage.sql.exec(statement);
      }
    });
  }

  async createUser(input: { username: string; password: string; now: number }): Promise<{ ok: true; userId: string } | { ok: false; error: "exists" | "bad_username" | "bad_password" }> {
    const username = normalizeUsername(input.username);
    if (!username) return { ok: false, error: "bad_username" };
    if (!passwordAccepted(input.password)) return { ok: false, error: "bad_password" };
    const existing = this.ctx.storage.sql.exec<AccountRow>("SELECT username, user_id, password_salt, password_hash, iterations FROM account WHERE username = ?", username).toArray()[0];
    if (existing) return { ok: false, error: "exists" };
    const salt = crypto.getRandomValues(new Uint8Array(16));
    const hash = await hashPassword(input.password, salt, PBKDF2_ITERATIONS);
    const userId = crypto.randomUUID();
    this.ctx.storage.sql.exec(
      "INSERT INTO account (username, user_id, password_salt, password_hash, iterations, created_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
      username,
      userId,
      bytesToBase64(salt),
      bytesToBase64(hash),
      PBKDF2_ITERATIONS,
      input.now,
    );
    return { ok: true, userId };
  }

  async deleteUser(userId: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM account WHERE user_id = ?", userId);
  }

  // Signs out every web and app session. Device tokens stay, so collectors keep uploading.
  async updatePassword(input: { userId: string; password: string }): Promise<void> {
    if (!passwordAccepted(input.password)) throw new Error("bad_password");
    const salt = crypto.getRandomValues(new Uint8Array(16));
    const hash = await hashPassword(input.password, salt, PBKDF2_ITERATIONS);
    this.ctx.storage.sql.exec(
      "UPDATE account SET password_salt = ?, password_hash = ?, iterations = ? WHERE user_id = ?",
      bytesToBase64(salt),
      bytesToBase64(hash),
      PBKDF2_ITERATIONS,
      input.userId,
    );
    this.ctx.storage.sql.exec("DELETE FROM token WHERE user_id = ? AND kind = 'session'", input.userId);
  }

  async forgetSession(tokenHash: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM token WHERE token_hash = ? AND kind = 'session'", tokenHash);
  }

  async verify(input: { username: string; password: string }): Promise<{ userId: string; username: string } | null> {
    const username = normalizeUsername(input.username);
    if (!username || !passwordAccepted(input.password)) {
      await dummyHash(input.password || "missing-password");
      return null;
    }
    const row = this.ctx.storage.sql.exec<AccountRow>("SELECT username, user_id, password_salt, password_hash, iterations FROM account WHERE username = ?", username).toArray()[0];
    if (!row) {
      await dummyHash(input.password);
      return null;
    }
    const actual = await hashPassword(input.password, base64ToBytes(row.password_salt), row.iterations);
    if (!timingSafeEqual(actual, base64ToBytes(row.password_hash))) return null;
    return { userId: row.user_id, username: row.username };
  }

  async lookup(username: string): Promise<{ userId: string; username: string } | null> {
    const normalized = normalizeUsername(username);
    if (!normalized) return null;
    const row = this.ctx.storage.sql.exec<{ user_id: string; username: string }>("SELECT user_id, username FROM account WHERE username = ?", normalized).toArray()[0];
    return row ? { userId: row.user_id, username: row.username } : null;
  }

  async rememberToken(input: { tokenHash: string; userId: string; kind: "session" | "device"; deviceId: string | null; expiresAtMs: number | null }): Promise<void> {
    if (input.kind === "device" && input.deviceId) {
      this.ctx.storage.sql.exec("DELETE FROM token WHERE device_id = ? AND kind = 'device'", input.deviceId);
    }
    this.ctx.storage.sql.exec("DELETE FROM token WHERE token_hash = ?", input.tokenHash);
    this.ctx.storage.sql.exec(
      "INSERT INTO token (token_hash, user_id, kind, device_id, expires_at_ms) VALUES (?, ?, ?, ?, ?)",
      input.tokenHash,
      input.userId,
      input.kind,
      input.deviceId,
      input.expiresAtMs,
    );
  }

  async findToken(input: { tokenHash: string; now: number }): Promise<{ userId: string; kind: string; expiresAtMs: number | null } | null> {
    const row = this.ctx.storage.sql
      .exec<{ user_id: string; kind: string; expires_at_ms: number | null }>("SELECT user_id, kind, expires_at_ms FROM token WHERE token_hash = ?", input.tokenHash)
      .toArray()[0];
    if (!row) return null;
    if (row.expires_at_ms !== null && row.expires_at_ms <= input.now) return null;
    return { userId: row.user_id, kind: row.kind, expiresAtMs: row.expires_at_ms };
  }

  async extendSession(input: { tokenHash: string; expiresAtMs: number }): Promise<void> {
    this.ctx.storage.sql.exec("UPDATE token SET expires_at_ms = ? WHERE token_hash = ? AND kind = 'session'", input.expiresAtMs, input.tokenHash);
  }
}
