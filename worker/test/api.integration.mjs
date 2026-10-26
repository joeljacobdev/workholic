import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

const port = 8791;
const root = new URL("..", import.meta.url).pathname;
const token = "local-dev-bootstrap";
const base = `http://127.0.0.1:${port}`;
const persist = mkdtempSync(join(tmpdir(), "workholic-do-"));

function waitForReady(child) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("wrangler did not become ready")), 60_000);
    let buffer = "";
    const onData = (chunk) => {
      buffer += chunk.toString();
      if (buffer.includes("Ready on") || buffer.includes(`http://127.0.0.1:${port}`)) {
        clearTimeout(timer);
        resolve();
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`wrangler exited ${code} before ready\n${buffer}`));
    });
  });
}

async function request(path, { method = "GET", token: bearer, bootstrap, body } = {}) {
  const headers = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  if (bootstrap) headers["x-bootstrap-token"] = bootstrap;
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text };
  }
  return { status: response.status, body: parsed };
}

const child = spawn(
  "npx",
  ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1", "--persist-to", persist, "--var", `WORKHOLIC_BOOTSTRAP_TOKEN:${token}`],
  { cwd: root, stdio: ["ignore", "pipe", "pipe"] },
);

try {
  await waitForReady(child);
  const health = await request("/health");
  assert.equal(health.status, 200);

  const signup = await request("/v1/signup", { method: "POST", body: { username: "tester", password: "whatever1" } });
  assert.equal(signup.status, 404);
  assert.equal(signup.body.error, "no_signup");

  const missing = await request("/v1/admin/users", {
    method: "POST",
    body: { username: "tester", password: "local-pass-1", timezone: "America/Los_Angeles" },
  });
  assert.equal(missing.status, 401);

  const created = await request("/v1/admin/users", {
    method: "POST",
    bootstrap: token,
    body: { username: "Tester", password: "local-pass-1", timezone: "America/Los_Angeles" },
  });
  assert.equal(created.status, 201);
  assert.equal(created.body.username, "tester");

  const again = await request("/v1/admin/users", {
    method: "POST",
    bootstrap: token,
    body: { username: "tester", password: "local-pass-1", timezone: "America/Los_Angeles" },
  });
  assert.equal(again.status, 409);

  const badLogin = await request("/v1/login", { method: "POST", body: { username: "tester", password: "wrong-password" } });
  assert.equal(badLogin.status, 401);

  const login = await request("/v1/login", { method: "POST", body: { username: "tester", password: "local-pass-1" } });
  assert.equal(login.status, 200);
  const session = login.body.session_token;

  const deviceId = "8b6c1c0e-3a1a-4e0a-9f1a-0c2b7a6d5e11";
  const enrolled = await request("/v1/devices", {
    method: "POST",
    token: session,
    body: { device_id: deviceId, display_name: "mbp", platform: "macos", role: "collector" },
  });
  assert.equal(enrolled.status, 200);
  const device = enrolled.body.device_token;

  const start = Date.parse("2026-10-04T17:00:00.000Z");
  const interval = {
    interval_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    start_wall_ms: start,
    end_wall_ms: start + 120_000,
    duration_ms: 120_000,
    app_key: "com.apple.Terminal",
    app_display_name: "Terminal",
    source: "os-window",
    browser_family: null,
    attendance: "input",
    input_marks: [{ at_ms: start + 60_000, input_ms: start + 50_000 }],
    media_bout_start_ms: null,
    site_unknown: 0,
    audible: null,
    boot_id: "1",
  };
  const uploadBody = {
    batch_id: "6d1c2a10-1111-4222-8333-444455556666",
    device_wall_at_send: Date.now(),
    upload_period_ms: 300_000,
    intervals: [interval],
  };
  const uploaded = await request(`/v1/devices/${deviceId}/intervals:upload`, {
    method: "POST",
    token: device,
    body: uploadBody,
  });
  assert.equal(uploaded.status, 200, JSON.stringify(uploaded.body));
  assert.equal(uploaded.body.accepted, 1);

  const duplicate = await request(`/v1/devices/${deviceId}/intervals:upload`, {
    method: "POST",
    token: device,
    body: uploadBody,
  });
  assert.equal(duplicate.status, 200);
  assert.equal(duplicate.body.duplicate_batch, true);

  const mismatch = await request(`/v1/devices/${deviceId}/intervals:upload`, {
    method: "POST",
    token: device,
    body: { ...uploadBody, intervals: [{ ...interval, duration_ms: 120_000, app_key: "Mail" }] },
  });
  assert.equal(mismatch.status, 409);

  const stats = await request("/v1/stats?from=2026-10-04&to=2026-10-04", { token: session });
  assert.equal(stats.status, 200, JSON.stringify(stats.body));
  assert.equal(stats.body.days[0].credited_ms, 120_000);
  assert.equal(stats.body.days[0].ceiling_ms, null);
  assert.deepEqual(stats.body.device_info.map((info) => [info.device_id, info.display_name]), [[deviceId, "mbp"]]);

  const day = await request("/v1/days/2026-10-04", { token: session });
  assert.equal(day.status, 200, JSON.stringify(day.body));
  assert.equal(day.body.credited_ms, 120_000);
  assert.deepEqual(day.body.segments, [{ device_id: deviceId, app_key: "com.apple.Terminal", start_ms: start, end_ms: start + 120_000 }]);
  assert.deepEqual(day.body.devices[0].apps, [{ appKey: "com.apple.Terminal", creditedMs: 120_000 }]);
  assert.equal((await request("/v1/days/2026-10-04")).status, 401);
  assert.equal((await request("/v1/days/2026-13-45", { token: session })).status, 422);

  const limit = await request("/v1/admin/limits", {
    method: "POST",
    bootstrap: token,
    body: { username: "tester", limit_ms: 8 * 60 * 60 * 1000 },
  });
  assert.equal(limit.status, 200);
  // A limit applies from now on, so read it on today's date in the account's zone, not on the fixture day.
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(new Date());
  const withCeiling = await request(`/v1/stats?from=${today}&to=${today}`, { token: session });
  assert.equal(withCeiling.body.days[0].ceiling_ms, 8 * 60 * 60 * 1000);
  assert.equal(withCeiling.body.days[0].over, false);

  const skewed = await request(`/v1/devices/${deviceId}/intervals:upload`, {
    method: "POST",
    token: device,
    body: {
      batch_id: "6d1c2a10-1111-4222-8333-444455556667",
      device_wall_at_send: Date.now() - 20 * 60 * 1000,
      upload_period_ms: 300_000,
      intervals: [{ ...interval, interval_id: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee" }],
    },
  });
  assert.equal(skewed.status, 422);
  assert.equal(skewed.body.error, "clock_offset");

  const defaultBreaks = await request("/v1/breaks", { token: device });
  assert.equal(defaultBreaks.status, 200);
  assert.equal(defaultBreaks.body.updated_at_ms, 0);
  assert.equal(defaultBreaks.body.enabled, true);
  const breakBody = {
    enabled: false,
    every_minutes: 50,
    items: [{ id: "6f9619ff-8b86-4011-b42d-00c04fc964ff", message: "Walk.", minutes: 10, rest: true }],
  };
  assert.equal((await request("/v1/breaks", { method: "PUT", token: device, body: breakBody })).status, 401, "device token cannot save");
  assert.equal((await request("/v1/breaks", { method: "PUT", token: session, body: { ...breakBody, every_minutes: 0 } })).status, 422);
  const savedBreaks = await request("/v1/breaks", { method: "PUT", token: session, body: breakBody });
  assert.equal(savedBreaks.status, 200, JSON.stringify(savedBreaks.body));
  assert.ok(savedBreaks.body.updated_at_ms > 0);
  const readBack = await request("/v1/breaks", { token: device });
  assert.equal(readBack.body.enabled, false);
  assert.equal(readBack.body.every_minutes, 50);
  assert.equal(readBack.body.items[0].message, "Walk.");
  assert.equal(readBack.body.overtime.enabled, false, "newer kinds read with defaults");
  assert.deepEqual(readBack.body.scheduled, []);

  const overtime = { enabled: true, every_minutes: 20, message: "Past the limit.", minutes: 5, rest: true };
  const lunch = { id: "7f9619ff-8b86-4011-b42d-00c04fc964ff", at: "13:00", message: "Lunch.", minutes: 45 };
  const newer = await request("/v1/breaks", { method: "PUT", token: session, body: { ...breakBody, overtime, scheduled: [lunch] } });
  assert.equal(newer.status, 200, JSON.stringify(newer.body));
  assert.equal((await request("/v1/breaks", { method: "PUT", token: session, body: { ...breakBody, scheduled: [{ ...lunch, at: "24:00" }] } })).body.error, "bad_scheduled");
  const olderMac = await request("/v1/breaks", { method: "PUT", token: session, body: { ...breakBody, every_minutes: 40 } });
  assert.equal(olderMac.status, 200, JSON.stringify(olderMac.body));
  const merged = await request("/v1/breaks", { token: device });
  assert.equal(merged.body.every_minutes, 40);
  assert.deepEqual(merged.body.overtime, overtime, "an old-shape save keeps the newer kinds");
  assert.equal(merged.body.scheduled[0].at, "13:00");
  const pulse = await request("/v1/settings", { token: device });
  assert.equal(pulse.body.breaks_updated_at_ms, merged.body.updated_at_ms, "settings says when breaks last changed");

  const page = await fetch(`${base}/`);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /id="login-form"/);
  assert.match(page.headers.get("content-security-policy") ?? "", /script-src 'self'/);
  for (const module of ["main", "core", "day", "history", "devices", "breaks", "settings", "plan", "dialog", "tip"]) {
    const script = await fetch(`${base}/js/${module}.js`);
    assert.equal(script.status, 200, module);
    assert.equal(script.headers.get("cache-control"), "no-cache", `${module} is checked on every load`);
  }
  const unknownApi = await request("/v1/nope");
  assert.equal(unknownApi.status, 404);

  const ownLimit = await request("/v1/limits", { method: "POST", token: session, body: { limit_ms: 6 * 60 * 60 * 1000 } });
  assert.equal(ownLimit.status, 200);
  assert.equal((await request("/v1/settings", { token: device })).body.limit_ms, 6 * 60 * 60 * 1000, "settings carries the limit in force");

  // Kiritimati is UTC+14, so the 17:00 UTC interval moves from Oct 4 to Oct 5.
  const zoned = await request("/v1/admin/timezone", {
    method: "POST",
    bootstrap: token,
    body: { username: "tester", timezone: "Pacific/Kiritimati" },
  });
  assert.equal(zoned.status, 200, JSON.stringify(zoned.body));
  const moved = await request("/v1/stats?from=2026-10-04&to=2026-10-05", { token: session });
  assert.equal(moved.body.timezone, "Pacific/Kiritimati");
  assert.equal(moved.body.days[0].credited_ms, 0);
  assert.equal(moved.body.days[1].credited_ms, 120_000);

  const shortPassword = await request("/v1/admin/password", { method: "POST", bootstrap: token, body: { username: "tester", password: "short" } });
  assert.equal(shortPassword.status, 422);
  const changed = await request("/v1/admin/password", {
    method: "POST",
    bootstrap: token,
    body: { username: "tester", password: "local-pass-2" },
  });
  assert.equal(changed.status, 200);
  assert.equal((await request("/v1/settings", { token: session })).status, 401, "old session is signed out");
  assert.equal((await request("/v1/settings", { token: device })).status, 200, "device token survives");
  assert.equal((await request("/v1/login", { method: "POST", body: { username: "tester", password: "local-pass-1" } })).status, 401);
  const relogin = await request("/v1/login", { method: "POST", body: { username: "tester", password: "local-pass-2" } });
  assert.equal(relogin.status, 200);

  // Remote shutdown: a session asks, only that device reads and acknowledges, once.
  const web = relogin.body.session_token;
  const shutdownPath = `/v1/devices/${deviceId}/shutdown`;
  const commandsPath = `/v1/devices/${deviceId}/commands`;
  const otherId = "1f0e2d3c-4b5a-4968-8776-655443322110";
  assert.equal((await request(shutdownPath, { method: "POST", token: device })).status, 401, "a device token cannot ask for a shutdown");
  assert.equal((await request(shutdownPath, { method: "POST" })).status, 401);
  assert.equal((await request(`/v1/devices/${otherId}/shutdown`, { method: "POST", token: web })).status, 404);
  const firstCheck = await request(commandsPath, { token: device });
  assert.deepEqual(firstCheck.body.commands, [], "nothing pending yet");
  const settingsNow = (await request("/v1/settings", { token: web })).body;
  assert.deepEqual(
    firstCheck.body.settings,
    {
      idle_threshold_ms: settingsNow.idle_threshold_ms,
      limit_ms: settingsNow.limit_ms,
      breaks_updated_at_ms: settingsNow.breaks_updated_at_ms,
    },
    "the order check carries the settings check",
  );
  assert.equal((await request(commandsPath, { token: web })).status, 401, "a session cannot read a device's orders");
  assert.equal((await request(`/v1/devices/${otherId}/commands`, { token: device })).status, 403, "a device reads only its own orders");

  const asked = await request(shutdownPath, { method: "POST", token: web });
  assert.equal(asked.status, 200);
  assert.equal(asked.body.state, "pending");
  const askedAgain = await request(shutdownPath, { method: "POST", token: web });
  assert.equal(askedAgain.body.command_id, asked.body.command_id, "asking twice keeps one order");
  const cancelled = await request(shutdownPath, { method: "DELETE", token: web });
  assert.equal(cancelled.body.shutdown.state, "cancelled");
  assert.deepEqual((await request(commandsPath, { token: device })).body.commands, [], "a cancelled order is not handed out");
  const lateAck = await request(`${commandsPath}/${asked.body.command_id}:ack`, { method: "POST", token: device, body: { result: "delivered" } });
  assert.equal(lateAck.body.go, false, "an order cancelled before the ack must not run");

  const order = (await request(shutdownPath, { method: "POST", token: web })).body;
  assert.notEqual(order.command_id, asked.body.command_id);
  const pending = await request(commandsPath, { token: device });
  assert.deepEqual(pending.body.commands.map((command) => [command.command_id, command.kind]), [[order.command_id, "shutdown"]]);
  const ackPath = `${commandsPath}/${order.command_id}:ack`;
  assert.equal((await request(ackPath, { method: "POST", token: device, body: { result: "rm -rf" } })).status, 422);
  assert.equal((await request(ackPath, { method: "POST", token: device, body: { result: "delivered" } })).body.go, true);
  assert.equal((await request(ackPath, { method: "POST", token: device, body: { result: "delivered" } })).body.go, false, "a second ack does not run it twice");
  assert.deepEqual((await request(commandsPath, { token: device })).body.commands, [], "a delivered order is not handed out again");
  assert.equal((await request(shutdownPath, { method: "DELETE", token: web })).body.shutdown.state, "delivered", "a delivered order cannot be called back");
  await request(ackPath, { method: "POST", token: device, body: { result: "failed:-128" } });
  const shown = (await request("/v1/stats", { token: web })).body.device_info.find((info) => info.device_id === deviceId);
  assert.equal(shown.shutdown.state, "failed");
  assert.equal(shown.shutdown.result, "failed:-128");
  assert.ok(shown.last_seen_at_ms > 0, "polling marks the device as seen");

  // The day plan: one for the account, set with a session, read by every Mac with its orders.
  const secondId = "2c4e6a8b-0d1f-4a3b-8c5d-7e9f0a1b2c3d";
  const second = (await request("/v1/devices", {
    method: "POST",
    token: web,
    body: { device_id: secondId, display_name: "studio", platform: "macos", role: "collector" },
  })).body.device_token;
  const both = [deviceId, secondId];
  assert.equal(shown.shutdown_schedule, undefined, "Macs no longer have schedules of their own");
  const fresh = await request(commandsPath, { token: device });
  assert.equal(fresh.body.day_plan_updated_at_ms, 0, "no plan saved yet");
  assert.equal(fresh.body.day_plan.mode, "limit", "the default is a limit and nothing else");
  assert.equal(fresh.body.shutdown_schedule, null);
  assert.equal((await request(`${commandsPath}?plan_at=0`, { token: device })).body.day_plan, undefined, "a Mac with the latest plan is not sent it again");

  const nightly = { mode: "limit", shutdown: "time", at: 1380, command: "last-call-end" };
  assert.equal((await request("/v1/day-plan", { method: "PUT", token: device, body: { plan: nightly } })).status, 401, "a device token cannot set the plan");
  assert.equal((await request("/v1/day-plan", { method: "PUT", token: web, body: { plan: { ...nightly, command: "../x" } } })).status, 422);
  assert.equal((await request("/v1/day-plan", { method: "PUT", token: web, body: { plan: nightly, limit_ms: -5 } })).status, 422);
  assert.equal((await request("/v1/day-plan", { method: "PUT", token: web, body: {} })).status, 422);
  const savedPlan = await request("/v1/day-plan", { method: "PUT", token: web, body: { plan: nightly, limit_ms: 5 * 3_600_000 } });
  assert.equal(savedPlan.status, 200);
  assert.equal(savedPlan.body.limit_ms, 5 * 3_600_000, "the limit is saved with the plan");
  assert.equal(savedPlan.body.day_plan.at, 1380);
  const planAt = savedPlan.body.day_plan_updated_at_ms;
  const legacy = { when: "time", after: "23:00", delay_minutes: 0, command: "last-call-end" };
  for (const [path, token] of [[commandsPath, device], [`/v1/devices/${secondId}/commands`, second]]) {
    const check = (await request(path, { token })).body;
    assert.equal(check.day_plan.shutdown, "time", "every Mac gets the one plan");
    assert.deepEqual(check.shutdown_schedule, legacy, "older Macs get it as a clock time");
  }
  assert.equal((await request(`${commandsPath}?plan_at=${planAt}`, { token: device })).body.day_plan, undefined);
  assert.equal((await request(`${commandsPath}?plan_at=${planAt - 1}`, { token: device })).body.day_plan.at, 1380, "an older copy is replaced");
  const viaSettings = (await request("/v1/settings", { token: web })).body;
  assert.equal(viaSettings.day_plan_updated_at_ms, planAt);
  assert.equal(viaSettings.limit_ms, 5 * 3_600_000);
  const sameLimit = await request("/v1/day-plan", { method: "PUT", token: web, body: { plan: { mode: "planner", weekdays: [[540, 1080]], weekends: [[540, 1080]], shutdown: "last_block" }, limit_ms: 5 * 3_600_000 } });
  assert.equal(sameLimit.body.day_plan.mode, "planner");
  assert.equal((await request(commandsPath, { token: device })).body.shutdown_schedule.after, "18:00", "after the last block, as a clock time for older Macs");
  await request("/v1/day-plan", { method: "PUT", token: web, body: { plan: { mode: "limit" } } });
  assert.equal((await request(commandsPath, { token: device })).body.shutdown_schedule, null, "turned off");

  // Several Macs at once: one shutdown for every Mac named, or for none.
  assert.equal((await request("/v1/shutdowns", { method: "POST", token: device, body: { device_ids: both } })).status, 401, "a device token cannot ask for shutdowns");
  assert.equal((await request("/v1/shutdowns", { method: "POST", token: web, body: { device_ids: [secondId, otherId] } })).status, 404);
  assert.deepEqual((await request(`/v1/devices/${secondId}/commands`, { token: second })).body.commands, [], "an unknown Mac in the list asks none");
  const askedBoth = await request("/v1/shutdowns", { method: "POST", token: web, body: { device_ids: both } });
  assert.equal(askedBoth.status, 200);
  assert.deepEqual(askedBoth.body.shutdowns.map((entry) => [entry.device_id, entry.shutdown.state]), [[deviceId, "pending"], [secondId, "pending"]]);
  const askedBothAgain = await request("/v1/shutdowns", { method: "POST", token: web, body: { device_ids: both } });
  assert.deepEqual(
    askedBothAgain.body.shutdowns.map((entry) => entry.shutdown.command_id),
    askedBoth.body.shutdowns.map((entry) => entry.shutdown.command_id),
    "asking twice keeps one order each",
  );
  const listedBoth = (await request("/v1/stats", { token: web })).body.device_info;
  assert.deepEqual(listedBoth.map((info) => info.shutdown?.state), ["pending", "pending"], "the device list shows each Mac's latest");
  for (const id of both) await request(`/v1/devices/${id}/shutdown`, { method: "DELETE", token: web });

  const loggedOut = await request("/v1/logout", { method: "POST", token: relogin.body.session_token });
  assert.equal(loggedOut.status, 200);
  assert.equal((await request("/v1/settings", { token: relogin.body.session_token })).status, 401, "logout revokes the session");

  let limited = false;
  for (let attempt = 0; attempt < 12 && !limited; attempt += 1) {
    const result = await request("/v1/login", { method: "POST", body: { username: "tester", password: "wrong-password" } });
    limited = result.status === 429;
  }
  assert.ok(limited, "login is rate limited");

  console.log("api ok");
} finally {
  child.kill("SIGTERM");
}
