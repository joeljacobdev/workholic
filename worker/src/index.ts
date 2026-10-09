import { parseBreakSettings } from "./breaks";
import { isValidTimeZone } from "./day";
import { Directory, normalizeUsername, passwordAccepted } from "./directory";
import { sameSecret, sha256Hex } from "./password";
import { SESSION_MS, SESSION_RENEW_AFTER_MS, UserAccount, type IntervalInput } from "./user-account";

export { Directory, UserAccount };

const MAX_BODY = 512_000;

function json(data: unknown, status = 200): Response {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
}

function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length).trim();
  return token.length > 0 ? token : null;
}

async function readJson(request: Request): Promise<{ ok: true; value: unknown } | { ok: false; response: Response }> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY) return { ok: false, response: json({ error: "too_large" }, 413) };
  const text = await request.text();
  if (text.length > MAX_BODY) return { ok: false, response: json({ error: "too_large" }, 413) };
  try {
    return { ok: true, value: text.length === 0 ? {} : JSON.parse(text) };
  } catch {
    return { ok: false, response: json({ error: "bad_json" }, 422) };
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

function directory(env: Env): DurableObjectStub<Directory> {
  return env.DIRECTORY.getByName("accounts");
}

function account(env: Env, userId: string): DurableObjectStub<UserAccount> {
  return env.USER.getByName(userId);
}

// Operator secret for creating a user and changing a ceiling. It is not a client
// lock: login, upload, and stats accept any client that presents that user's
// session or device token. An empty token fails closed.
async function authorizedBootstrap(request: Request, env: Env): Promise<boolean> {
  const expected = env.WORKHOLIC_BOOTSTRAP_TOKEN;
  const presented = request.headers.get("X-Bootstrap-Token") ?? "";
  if (!expected || !presented) return false;
  return sameSecret(presented, expected);
}

// The web app in public/ is served as static assets before this handler runs.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
    if (request.method === "POST" && url.pathname === "/v1/signup") return json({ error: "no_signup" }, 404);

    try {
      if (request.method === "POST" && url.pathname === "/v1/admin/users") return await createUser(request, env);
      if (request.method === "POST" && url.pathname === "/v1/admin/limits") return await setLimit(request, env);
      if (request.method === "POST" && url.pathname === "/v1/admin/timezone") return await setTimezone(request, env);
      if (request.method === "POST" && url.pathname === "/v1/admin/password") return await setPassword(request, env);
      if (request.method === "POST" && url.pathname === "/v1/limits") return await setOwnLimit(request, env);
      if (request.method === "POST" && url.pathname === "/v1/login") return await login(request, env);
      if (request.method === "POST" && url.pathname === "/v1/logout") return await logout(request, env);
      if (request.method === "POST" && url.pathname === "/v1/devices") return await enroll(request, env);
      if (request.method === "GET" && url.pathname === "/v1/stats") return await stats(request, env, url);
      if (request.method === "GET" && url.pathname === "/v1/settings") return await settings(request, env);
      const dayPath = /^\/v1\/days\/(\d{4}-\d{2}-\d{2})$/.exec(url.pathname);
      if (request.method === "GET" && dayPath) return await dayDetail(request, env, dayPath[1]);
      if (request.method === "GET" && url.pathname === "/v1/breaks") return await getBreaks(request, env);
      if (request.method === "PUT" && url.pathname === "/v1/breaks") return await putBreaks(request, env);
      const upload = /^\/v1\/devices\/([0-9a-f-]{36})\/intervals:upload$/.exec(url.pathname);
      if (request.method === "POST" && upload) return await uploadIntervals(request, env, upload[1]);
      return json({ error: "not_found" }, 404);
    } catch (error) {
      console.log(JSON.stringify({ error: error instanceof Error ? error.name : "unknown" }));
      return json({ error: "server" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function createUser(request: Request, env: Env): Promise<Response> {
  if (!(await authorizedBootstrap(request, env))) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const username = typeof record?.username === "string" ? record.username : "";
  const password = typeof record?.password === "string" ? record.password : "";
  const timezone = typeof record?.timezone === "string" ? record.timezone : "";
  if (!normalizeUsername(username)) return json({ error: "bad_username" }, 422);
  if (!passwordAccepted(password)) return json({ error: "bad_password" }, 422);
  if (!isValidTimeZone(timezone)) return json({ error: "bad_timezone" }, 422);
  const now = Date.now();
  const created = await directory(env).createUser({ username, password, now });
  if (!created.ok) return json({ error: created.error === "exists" ? "username_taken" : created.error }, created.error === "exists" ? 409 : 422);
  try {
    await account(env, created.userId).init({
      userId: created.userId,
      username: normalizeUsername(username) ?? username,
      timezone,
      now,
    });
  } catch (error) {
    await directory(env).deleteUser(created.userId);
    throw error;
  }
  return json({ username: normalizeUsername(username), user_id: created.userId }, 201);
}

async function setOwnLimit(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const limitMs = record?.limit_ms;
  if (!Number.isInteger(limitMs) || (limitMs as number) < 0) return json({ error: "bad_limit" }, 422);
  try {
    const result = await account(env, userId).setOwnLimit({ sessionToken: token, limitMs: limitMs as number, now: Date.now() });
    if ("error" in result) return json({ error: result.error }, 401);
    return json(result);
  } catch {
    return json({ error: "bad_limit" }, 422);
  }
}

async function setLimit(request: Request, env: Env): Promise<Response> {
  if (!(await authorizedBootstrap(request, env))) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const username = typeof record?.username === "string" ? record.username : "";
  const limitMs = record?.limit_ms;
  if (!Number.isInteger(limitMs) || (limitMs as number) < 0) return json({ error: "bad_limit" }, 422);
  const found = await directory(env).lookup(username);
  if (!found) return json({ error: "no_such_user" }, 404);
  try {
    const result = await account(env, found.userId).setLimit({ limitMs: limitMs as number, now: Date.now() });
    return json({ username: found.username, ...result });
  } catch {
    return json({ error: "bad_limit" }, 422);
  }
}

async function setTimezone(request: Request, env: Env): Promise<Response> {
  if (!(await authorizedBootstrap(request, env))) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const username = typeof record?.username === "string" ? record.username : "";
  const timezone = typeof record?.timezone === "string" ? record.timezone : "";
  if (!isValidTimeZone(timezone)) return json({ error: "bad_timezone" }, 422);
  const found = await directory(env).lookup(username);
  if (!found) return json({ error: "no_such_user" }, 404);
  const result = await account(env, found.userId).setTimezone({ timezone, now: Date.now() });
  return json({ username: found.username, timezone: result.timezone, days_rebuilt: result.daysRebuilt });
}

async function setPassword(request: Request, env: Env): Promise<Response> {
  if (!(await authorizedBootstrap(request, env))) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const username = typeof record?.username === "string" ? record.username : "";
  const password = typeof record?.password === "string" ? record.password : "";
  if (!passwordAccepted(password)) return json({ error: "bad_password" }, 422);
  const found = await directory(env).lookup(username);
  if (!found) return json({ error: "no_such_user" }, 404);
  await directory(env).updatePassword({ userId: found.userId, password });
  await account(env, found.userId).revokeSessions(Date.now());
  return json({ username: found.username, password_updated: true, sessions_revoked: true });
}

async function login(request: Request, env: Env): Promise<Response> {
  const client = request.headers.get("CF-Connecting-IP") ?? "local";
  const { success } = await env.LOGIN_LIMITER.limit({ key: client });
  if (!success) return json({ error: "rate_limited" }, 429);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const username = typeof record?.username === "string" ? record.username : "";
  const password = typeof record?.password === "string" ? record.password : "";
  const verified = await directory(env).verify({ username, password });
  if (!verified) return json({ error: "bad_login" }, 401);
  const session = await account(env, verified.userId).createSession(Date.now());
  await directory(env).rememberToken({
    tokenHash: await sha256Hex(session.token),
    userId: verified.userId,
    kind: "session",
    deviceId: null,
    expiresAtMs: session.expiresAtMs,
  });
  return json({
    session_token: session.token,
    expires_at_ms: session.expiresAtMs,
    username: session.username,
    timezone: session.timezone,
  });
}

async function logout(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const tokenHash = await sha256Hex(token);
  const found = await directory(env).findToken({ tokenHash, now: Date.now() });
  if (found) {
    await account(env, found.userId).endSession({ token, now: Date.now() });
    await directory(env).forgetSession(tokenHash);
  }
  return json({ ok: true });
}

async function enroll(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const record = asRecord(body.value);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const result = await account(env, userId).enrollDevice({
    sessionToken: token,
    now: Date.now(),
    deviceId: typeof record?.device_id === "string" ? record.device_id : "",
    displayName: typeof record?.display_name === "string" ? record.display_name : "",
    platform: typeof record?.platform === "string" ? record.platform : "",
    role: typeof record?.role === "string" ? record.role : "",
  });
  if (!result.ok) {
    const status = result.error === "bad_token" ? 401 : result.error === "not_collector" ? 403 : 422;
    return json({ error: result.error }, status);
  }
  const deviceId = typeof record?.device_id === "string" ? record.device_id : "";
  await directory(env).rememberToken({
    tokenHash: await sha256Hex(result.deviceToken),
    userId,
    kind: "device",
    deviceId,
    expiresAtMs: null,
  });
  return json({ device_id: deviceId, device_token: result.deviceToken });
}

async function stats(request: Request, env: Env, url: URL): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const result = await account(env, userId).stats({
    token,
    now: Date.now(),
    from: url.searchParams.get("from"),
    to: url.searchParams.get("to"),
  });
  if (!result) return json({ error: "bad_token" }, 401);
  if ("error" in result) return json({ error: result.error }, result.status);
  return json(result);
}

async function dayDetail(request: Request, env: Env, day: string): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const result = await account(env, userId).dayDetail({ token, now: Date.now(), day });
  if (!result) return json({ error: "bad_token" }, 401);
  if ("error" in result) return json({ error: result.error }, result.status);
  return json(result);
}

async function settings(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const result = await account(env, userId).settings({ token, now: Date.now() });
  if (!result) return json({ error: "bad_token" }, 401);
  return json({
    username: result.username,
    timezone: result.timezone,
    idle_threshold_ms: result.idleThresholdMs,
    limit_ms: result.limitMs,
    breaks_updated_at_ms: result.breaksUpdatedAtMs,
  });
}

async function getBreaks(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const result = await account(env, userId).breaks({ token, now: Date.now() });
  if (!result) return json({ error: "bad_token" }, 401);
  return json(result);
}

// Saving needs a login session; a Mac's device token can only read.
async function putBreaks(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const parsed = parseBreakSettings(body.value);
  if (!parsed.ok) return json({ error: parsed.error }, 422);
  const result = await account(env, userId).setBreaks({ sessionToken: token, settings: parsed.settings, now: Date.now() });
  if (!result) return json({ error: "bad_token" }, 401);
  return json(result);
}

async function uploadIntervals(request: Request, env: Env, deviceId: string): Promise<Response> {
  const token = bearer(request);
  if (!token) return json({ error: "bad_token" }, 401);
  const raw = await request.text();
  if (raw.length > MAX_BODY) return json({ error: "too_large" }, 413);
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return json({ error: "bad_json" }, 422);
  }
  const record = asRecord(parsed);
  if (!record || !Array.isArray(record.intervals)) return json({ error: "bad_batch" }, 422);
  const userId = await userIdForToken(env, token);
  if (!userId) return json({ error: "bad_token" }, 401);
  const bodySha256 = await sha256Hex(raw);
  const result = await account(env, userId).upload({
    deviceToken: token,
    pathDeviceId: deviceId,
    bodySha256,
    receivedAtMs: Date.now(),
    batchId: typeof record.batch_id === "string" ? record.batch_id : "",
    deviceWallAtSend: typeof record.device_wall_at_send === "number" ? record.device_wall_at_send : Number.NaN,
    uploadPeriodMs: typeof record.upload_period_ms === "number" ? record.upload_period_ms : 0,
    intervals: record.intervals as IntervalInput[],
  });
  const status = Number(result.status) || 200;
  const { status: _status, ...body } = result;
  return json(body, status);
}

// A login session in use stays signed in: once a day of its 30 has passed, its expiry moves
// out to 30 days from now. Device tokens do not expire.
async function userIdForToken(env: Env, token: string): Promise<string | null> {
  const tokenHash = await sha256Hex(token);
  const now = Date.now();
  const found = await directory(env).findToken({ tokenHash, now });
  if (!found) return null;
  if (found.kind === "session" && found.expiresAtMs !== null && found.expiresAtMs - now < SESSION_MS - SESSION_RENEW_AFTER_MS) {
    const expiresAtMs = await account(env, found.userId).renewSession({ token, now });
    if (expiresAtMs === null) return null;
    await directory(env).extendSession({ tokenHash, expiresAtMs });
  }
  return found.userId;
}
