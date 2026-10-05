"use strict";

const TOKEN_KEY = "workholic.session";
const TABS = ["today", "history", "day", "settings"];
const GAUGE_CIRCUMFERENCE = 2 * Math.PI * 50;
const REFRESH_MS = 60_000;
const HOUR_MS = 3_600_000;
const DEVICE_SLOTS = 5;
// Credited runs closer than this read as one stretch on the timeline.
const RUN_GAP_MS = 60_000;
const ALL_COLOR = "var(--all)";

const $ = (id) => document.getElementById(id);
let settings = null;
let refreshTimer = null;

class AuthError extends Error {}

function readToken() {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

function writeToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    // Private mode: the session lasts until the tab closes.
  }
}

async function api(path, { method = "GET", body } = {}) {
  const headers = {};
  const token = readToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  let data = null;
  try {
    data = await response.json();
  } catch {
    data = null;
  }
  if (response.status === 401) throw new AuthError();
  if (!response.ok) throw new Error(data?.error ?? `HTTP ${response.status}`);
  return data;
}

// ---- Formatting ----

function formatDuration(ms) {
  const minutes = Math.round(Math.max(0, ms) / 60_000);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

function dayKeyIn(timeZone, date = new Date()) {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

function shiftDay(key, delta) {
  const date = new Date(`${key}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
}

function dayLabel(key, todayKey) {
  if (key === todayKey) return "Today";
  if (key === shiftDay(todayKey, -1)) return "Yesterday";
  return new Intl.DateTimeFormat(undefined, { timeZone: "UTC", weekday: "short", day: "numeric" }).format(new Date(`${key}T12:00:00Z`));
}

function longDayLabel(key) {
  return new Intl.DateTimeFormat(undefined, { timeZone: "UTC", weekday: "long", month: "long", day: "numeric" }).format(new Date(`${key}T12:00:00Z`));
}

function clock(ms) {
  return new Intl.DateTimeFormat(undefined, { timeZone: settings.timezone, hour: "numeric", minute: "2-digit" }).format(new Date(ms));
}

function hourLabel(ms) {
  return new Intl.DateTimeFormat(undefined, { timeZone: settings.timezone, hour: "numeric" }).format(new Date(ms));
}

function ago(ms) {
  if (ms == null) return "never synced";
  const minutes = Math.round((Date.now() - ms) / 60_000);
  if (minutes < 2) return "synced just now";
  if (minutes < 60) return `synced ${minutes} min ago`;
  if (minutes < 48 * 60) return `synced ${Math.round(minutes / 60)} h ago`;
  return `synced ${Math.round(minutes / 1440)} days ago`;
}

function appName(key) {
  if (key === "unattributed") return "Unattributed";
  const last = key.includes(".") ? key.slice(key.lastIndexOf(".") + 1) : key;
  return last.charAt(0).toUpperCase() + last.slice(1);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function showError(message) {
  $("app-error").textContent = message;
  $("app-error").hidden = !message;
}

function showLogin(message) {
  stopRefresh();
  settings = null;
  breaksDirty = false;
  $("app-view").hidden = true;
  $("login-view").hidden = false;
  $("login-error").textContent = message ?? "";
  $("login-error").hidden = !message;
  $("username").focus();
}

function handleFailure(error) {
  if (error instanceof AuthError) {
    writeToken(null);
    showLogin("Your session ended. Log in again.");
    return;
  }
  showError(navigator.onLine ? `Could not reach Workholic (${error.message}).` : "You are offline. Showing the last numbers loaded.");
}

// ---- Devices ----
// A device keeps the color of its enrollment order, so it looks the same on every day.

function deviceBook(info) {
  const byId = new Map();
  info.forEach((device, index) => {
    byId.set(device.device_id, {
      ...device,
      order: index,
      color: index < DEVICE_SLOTS ? `var(--dev-${index + 1})` : "var(--dev-other)",
    });
  });
  return (id) =>
    byId.get(id) ?? { device_id: id, display_name: "Removed device", platform: "", last_upload_at_ms: null, order: info.length, color: "var(--dev-other)" };
}

// Stacks keep enrollment order so the same device sits in the same place on every bar.
function byEnrollment(device) {
  return (a, b) => device(a.deviceId).order - device(b.deviceId).order;
}

function swatch(color) {
  const node = el("span", "swatch");
  node.style.setProperty("--c", color);
  return node;
}

function stackBar(parts, total) {
  const bar = el("div", "stack");
  for (const part of parts) {
    if (part.ms <= 0) continue;
    const span = el("span");
    span.style.setProperty("--c", part.color);
    span.style.flex = `0 0 calc(${(part.ms / total) * 100}% - 2px)`;
    if (part.tip) setTip(span, part.tip);
    bar.append(span);
  }
  return bar;
}

// ---- Device focus ----
// Everything shows all devices together until one is picked. The pick holds across days and tabs.

let focus = null;
let lastDay = null;
let lastStats = null;

function setFocus(id) {
  focus = focus === id ? null : id;
  $("tip").hidden = true;
  if (currentTab() === "history") {
    if (lastStats) renderHistory(lastStats);
  } else if (lastDay) {
    renderDay(lastDay.container, lastDay.detail);
  }
}

function focusBar(ids, device) {
  const bar = el("div", "focus");
  bar.setAttribute("role", "group");
  bar.setAttribute("aria-label", "Show time for");
  const all = el("button", "chip", "All devices");
  all.type = "button";
  all.setAttribute("aria-pressed", String(focus === null));
  all.addEventListener("click", () => setFocus(null));
  bar.append(all);
  for (const id of ids) {
    const info = device(id);
    const chip = el("button", "chip");
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(focus === id));
    chip.append(swatch(info.color), el("span", "", info.display_name));
    chip.addEventListener("click", () => setFocus(id));
    bar.append(chip);
  }
  return bar;
}

// ---- Tooltip ----

const tips = new WeakMap();

function setTip(node, build) {
  tips.set(node, build);
}

function tipLine(color, text) {
  const row = el("div", "tip-row");
  if (color) row.append(swatch(color));
  row.append(document.createTextNode(text));
  return row;
}

function placeTip(event) {
  const tip = $("tip");
  let node = event.target instanceof Element ? event.target : null;
  while (node && !tips.has(node)) node = node.parentElement;
  if (!node) {
    tip.hidden = true;
    return;
  }
  tip.replaceChildren(...tips.get(node)());
  tip.hidden = false;
  const pad = 12;
  const { width, height } = tip.getBoundingClientRect();
  let x = event.clientX + pad;
  let y = event.clientY - height - pad;
  if (x + width > window.innerWidth - 8) x = event.clientX - width - pad;
  if (y < 8) y = event.clientY + pad;
  tip.style.left = `${Math.max(8, x)}px`;
  tip.style.top = `${y}px`;
}

document.addEventListener("pointermove", placeTip);
document.addEventListener("pointerdown", placeTip);
document.addEventListener("scroll", () => ($("tip").hidden = true), { passive: true });

// ---- One day, in depth ----

/** What the timeline and app list show: every device together, or the focused one. */
function dayView(detail, device) {
  if (focus === null) {
    return { all: true, color: ALL_COLOR, label: "All devices", creditedMs: detail.credited_ms, segments: detail.segments, apps: detail.apps };
  }
  const entry = detail.devices.find((item) => item.deviceId === focus);
  return {
    all: false,
    color: device(focus).color,
    label: device(focus).display_name,
    creditedMs: entry?.creditedMs ?? 0,
    segments: detail.segments.filter((segment) => segment.device_id === focus),
    apps: entry?.apps ?? [],
  };
}

function runsOf(segments) {
  const runs = [];
  for (const segment of segments) {
    const ms = segment.end_ms - segment.start_ms;
    let run = runs[runs.length - 1];
    if (run && segment.start_ms - run.end_ms <= RUN_GAP_MS) {
      run.end_ms = Math.max(run.end_ms, segment.end_ms);
      run.credited_ms += ms;
    } else {
      run = { start_ms: segment.start_ms, end_ms: segment.end_ms, credited_ms: ms, apps: new Map(), devices: new Map() };
      runs.push(run);
    }
    run.apps.set(segment.app_key, (run.apps.get(segment.app_key) ?? 0) + ms);
    run.devices.set(segment.device_id, (run.devices.get(segment.device_id) ?? 0) + ms);
  }
  return runs;
}

/** Tooltip lines splitting a total across devices; only useful when showing all of them. */
function deviceLines(perDevice, device) {
  return [...perDevice.entries()]
    .map(([deviceId, ms]) => ({ deviceId, ms }))
    .sort(byEnrollment(device))
    .map((part) => tipLine(device(part.deviceId).color, `${device(part.deviceId).display_name} ${formatDuration(part.ms)}`));
}

function axis(detail, every) {
  const node = el("div", "axis");
  const span = detail.end_ms - detail.start_ms;
  const hours = Math.round(span / HOUR_MS);
  for (let hour = 0; hour <= hours; hour += every) {
    const at = Math.min(detail.start_ms + hour * HOUR_MS, detail.end_ms);
    const label = el("span", "", hourLabel(at));
    label.style.left = `${((at - detail.start_ms) / span) * 100}%`;
    node.append(label);
  }
  return node;
}

function devicesPanel(detail, device) {
  const panel = el("div", "panel");
  const head = el("div", "panel-head");
  head.append(el("h2", "", "Devices"));
  panel.append(head);
  const shown = detail.devices.filter((entry) => entry.rawMs > 0).sort((a, b) => b.creditedMs - a.creditedMs);
  if (shown.length === 0) {
    panel.append(el("p", "muted empty", "No device reported time on this day."));
    return panel;
  }
  if (shown.length > 1) head.append(el("p", "muted small", "Pick one to see only its time"));
  const total = Math.max(1, detail.credited_ms);
  panel.append(
    stackBar(
      [...shown].sort(byEnrollment(device)).map((entry) => ({
        ms: entry.creditedMs,
        color: device(entry.deviceId).color,
        tip: () => [el("strong", "", device(entry.deviceId).display_name), tipLine(null, `${formatDuration(entry.creditedMs)}, ${Math.round((entry.creditedMs / total) * 100)}%`)],
      })),
      total,
    ),
  );
  const list = el("ul", "devices");
  list.classList.toggle("focused", focus !== null);
  for (const entry of shown) {
    const info = device(entry.deviceId);
    const item = el("li");
    const row = el("button", "device-row");
    row.type = "button";
    row.setAttribute("aria-pressed", String(focus === entry.deviceId));
    row.addEventListener("click", () => setFocus(entry.deviceId));
    const overlap = entry.rawMs - entry.creditedMs;
    const meta = [];
    if (overlap >= 60_000) meta.push(`${formatDuration(overlap)} overlapped another device`);
    const top = entry.apps?.[0];
    if (top) meta.push(`mostly ${appName(top.appKey)}`);
    meta.push(ago(info.last_upload_at_ms));
    row.append(swatch(info.color), el("span", "name", info.display_name), el("span", "value", formatDuration(entry.creditedMs)));
    row.append(el("span", "meta", meta.join(", ")), el("span", "share", `${Math.round((entry.creditedMs / total) * 100)}%`));
    item.append(row);
    list.append(item);
  }
  panel.append(list);
  return panel;
}

function timelinePanel(detail, view, device, nowMs) {
  const panel = el("div", "panel");
  const head = el("div", "panel-head");
  head.append(el("h2", "", "Across the day"));
  panel.append(head);
  if (view.segments.length === 0) {
    panel.append(el("p", "muted empty", view.all ? "Nothing on the timeline yet." : `${view.label} has no time on this day.`));
    return panel;
  }
  const span = detail.end_ms - detail.start_ms;
  const first = view.segments[0].start_ms;
  const last = view.segments[view.segments.length - 1].end_ms;
  head.append(el("p", "muted small", `${formatDuration(view.creditedMs)}, first ${clock(first)}, last ${clock(last)}`));

  const lane = el("div", "lane");
  lane.setAttribute("aria-label", `${view.label}: active stretches through the day`);
  for (const run of runsOf(view.segments)) {
    const bar = el("i");
    bar.style.setProperty("--c", view.color);
    bar.style.left = `${((run.start_ms - detail.start_ms) / span) * 100}%`;
    bar.style.width = `${((run.end_ms - run.start_ms) / span) * 100}%`;
    setTip(bar, () => {
      const apps = [...run.apps.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3);
      return [
        el("strong", "", `${clock(run.start_ms)} – ${clock(run.end_ms)}, ${formatDuration(run.credited_ms)}`),
        ...(view.all && run.devices.size > 1 ? deviceLines(run.devices, device) : []),
        ...apps.map(([key, ms]) => tipLine(null, `${appName(key)} ${formatDuration(ms)}`)),
      ];
    });
    lane.append(bar);
  }
  if (nowMs > detail.start_ms && nowMs < detail.end_ms) {
    const now = el("b");
    now.style.left = `${((nowMs - detail.start_ms) / span) * 100}%`;
    now.title = "Now";
    lane.append(now);
  }
  panel.append(lane, axis(detail, 6));

  // Minutes per hour.
  const hours = Math.round(span / HOUR_MS);
  const grid = el("div", "hours");
  grid.setAttribute("role", "img");
  for (const level of [30, 60]) {
    const line = el("div", "grid");
    line.style.bottom = `${(level / 60) * 100}%`;
    line.append(el("em", "", `${level}m`));
    grid.append(line);
  }
  let busiest = { hour: -1, ms: 0 };
  for (let hour = 0; hour < hours; hour += 1) {
    const hourStart = detail.start_ms + hour * HOUR_MS;
    const hourEnd = Math.min(hourStart + HOUR_MS, detail.end_ms);
    const perDevice = new Map();
    let sum = 0;
    for (const segment of view.segments) {
      const overlap = Math.min(segment.end_ms, hourEnd) - Math.max(segment.start_ms, hourStart);
      if (overlap <= 0) continue;
      sum += overlap;
      perDevice.set(segment.device_id, (perDevice.get(segment.device_id) ?? 0) + overlap);
    }
    const column = el("div", "hour");
    if (sum > 0) {
      const fill = el("span");
      fill.style.setProperty("--c", view.color);
      fill.style.height = `${(sum / HOUR_MS) * 100}%`;
      column.append(fill);
    }
    if (sum > busiest.ms) busiest = { hour: hourStart, ms: sum };
    setTip(column, () => [
      el("strong", "", `${clock(hourStart)} – ${clock(hourEnd)}, ${sum === 0 ? "no time" : formatDuration(sum)}`),
      ...(view.all && perDevice.size > 1 ? deviceLines(perDevice, device) : []),
    ]);
    grid.append(column);
  }
  grid.setAttribute("aria-label", busiest.ms > 0 ? `Minutes per hour. Busiest hour starts ${clock(busiest.hour)} with ${formatDuration(busiest.ms)}.` : "Minutes per hour");
  const hoursHead = el("div", "panel-head");
  hoursHead.style.margin = "26px 0 22px";
  hoursHead.append(el("h3", "", "Minutes per hour"));
  if (busiest.ms > 0) {
    hoursHead.append(el("p", "muted small", `Busiest hour ${clock(busiest.hour)} – ${clock(Math.min(busiest.hour + HOUR_MS, detail.end_ms))}, ${formatDuration(busiest.ms)}`));
  }
  const hoursAxis = axis(detail, 6);
  hoursAxis.classList.add("hours-axis");
  panel.append(hoursHead, grid, hoursAxis);
  return panel;
}

function appsPanel(detail, view, device) {
  const panel = el("div", "panel");
  const head = el("div", "panel-head");
  head.append(el("h2", "", "Apps"));
  panel.append(head);
  const apps = view.apps.slice(0, 10);
  if (apps.length === 0) {
    const message = view.all ? "No app time on this day. Time appears after a Mac uploads, about every 5 minutes." : `${view.label} has no app time on this day.`;
    panel.append(el("p", "muted empty", message));
    return panel;
  }
  if (view.apps.length > apps.length) head.append(el("p", "muted small", `Top ${apps.length} of ${view.apps.length}`));
  const byApp = new Map();
  for (const entry of detail.devices) {
    for (const app of entry.apps ?? []) {
      const split = byApp.get(app.appKey) ?? new Map();
      split.set(entry.deviceId, app.creditedMs);
      byApp.set(app.appKey, split);
    }
  }
  const top = apps[0].creditedMs;
  const list = el("ol", "apps");
  for (const app of apps) {
    const item = el("li");
    const label = el("div", "label");
    const name = el("span", "name", appName(app.appKey));
    name.title = app.appKey;
    label.append(name, el("span", "value", formatDuration(app.creditedMs)));
    const split = byApp.get(app.appKey) ?? new Map();
    const bar = stackBar(
      [
        {
          ms: app.creditedMs,
          color: view.color,
          tip: () => [el("strong", "", `${appName(app.appKey)}, ${formatDuration(app.creditedMs)}`), ...(view.all && split.size > 1 ? deviceLines(split, device) : [])],
        },
      ],
      app.creditedMs,
    );
    bar.style.width = `${Math.max(2, (app.creditedMs / top) * 100)}%`;
    item.append(label, bar);
    list.append(item);
  }
  panel.append(list);
  return panel;
}

function renderDay(container, detail) {
  lastDay = { container, detail };
  const device = deviceBook(detail.device_info);
  const present = detail.devices.filter((entry) => entry.rawMs > 0).sort(byEnrollment(device)).map((entry) => entry.deviceId);
  if (focus !== null && !present.includes(focus)) present.push(focus);
  const view = dayView(detail, device);
  const nodes = [devicesPanel(detail, device)];
  if (present.length > 1 || focus !== null) nodes.push(focusBar(present, device));
  nodes.push(timelinePanel(detail, view, device, Date.now()), appsPanel(detail, view, device));
  container.replaceChildren(...nodes);
}

// ---- Today ----

async function loadToday() {
  const today = dayKeyIn(settings.timezone);
  const detail = await api(`/v1/days/${today}`);
  const used = detail.credited_ms;
  const limit = detail.ceiling_ms;
  const over = limit !== null && used > limit;

  $("today-used").textContent = formatDuration(used);
  $("today-of").textContent = limit === null ? "no daily limit" : `of ${formatDuration(limit)}`;
  const fraction = limit ? Math.min(used / limit, 1) : 0;
  const arc = $("gauge-arc");
  arc.style.strokeDasharray = String(GAUGE_CIRCUMFERENCE);
  arc.style.strokeDashoffset = String(GAUGE_CIRCUMFERENCE * (1 - fraction));
  arc.classList.toggle("over", over);

  $("today-date").textContent = over ? "Over today's limit" : "Left today";
  $("today-left").textContent = limit === null ? "No limit" : over ? formatDuration(used - limit) : formatDuration(limit - used);
  $("today-left").style.color = over ? "var(--over)" : "";
  $("today-limit").textContent = limit === null ? "Not set" : formatDuration(limit);
  $("today-devices").textContent = String(detail.devices.filter((entry) => entry.rawMs > 0).length);
  renderDay($("today-detail"), detail);

  if (limit !== null && document.activeElement?.closest("#limit-form") == null) {
    const minutes = Math.round(limit / 60_000);
    $("limit-hours").value = String(Math.floor(minutes / 60));
    $("limit-minutes").value = String(minutes % 60);
  }
  $("updated-at").textContent = new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

// ---- History ----

async function loadHistory() {
  const today = dayKeyIn(settings.timezone);
  const from = shiftDay(today, -13);
  renderHistory(await api(`/v1/stats?from=${from}&to=${today}`));
}

function renderHistory(stats) {
  lastStats = stats;
  const today = dayKeyIn(settings.timezone);
  const device = deviceBook(stats.device_info ?? []);
  const days = [...stats.days].reverse();
  const usedOn = (day) => (focus === null ? day.credited_ms : (day.devices.find((entry) => entry.deviceId === focus)?.creditedMs ?? 0));
  const color = focus === null ? ALL_COLOR : device(focus).color;
  // The limit covers all devices together, so it only marks the overall view.
  const scale = Math.max(HOUR_MS, ...days.map((day) => Math.max(usedOn(day), focus === null ? (day.ceiling_ms ?? 0) : 0)));

  const seen = (stats.device_info ?? [])
    .map((info) => info.device_id)
    .filter((id) => id === focus || days.some((day) => day.devices.some((entry) => entry.deviceId === id && entry.creditedMs > 0)));
  const bar = $("history-focus");
  if (seen.length > 1 || focus !== null) bar.replaceChildren(focusBar(seen, device));
  else bar.replaceChildren();

  const active = days.filter((day) => usedOn(day) > 0);
  const average = active.length ? active.reduce((sum, day) => sum + usedOn(day), 0) / active.length : 0;
  const overDays = focus === null ? days.filter((day) => day.over).length : 0;
  const who = focus === null ? "" : `${device(focus).display_name}: `;
  const summary = active.length
    ? `${who}average ${formatDuration(average)} on ${active.length} active ${active.length === 1 ? "day" : "days"}${overDays ? `, over the limit on ${overDays}` : ""}`
    : `${who}no tracked days yet`;
  $("history-summary").textContent = summary.charAt(0).toUpperCase() + summary.slice(1);

  const list = $("history-list");
  list.replaceChildren();
  for (const day of days) {
    const used = usedOn(day);
    const over = focus === null && day.over;
    const item = el("li");
    const link = el("a");
    link.href = `#day/${day.day}`;
    link.setAttribute("aria-label", `${longDayLabel(day.day)}: ${formatDuration(used)}${over ? ", over the limit" : ""}`);
    const track = el("div", "bar");
    const fill = stackBar([{ ms: used, color: over ? "var(--over)" : color }], Math.max(1, used));
    fill.style.width = `${(used / scale) * 100}%`;
    track.append(fill);
    if (focus === null && day.ceiling_ms !== null) {
      const mark = el("b");
      mark.style.left = `${(day.ceiling_ms / scale) * 100}%`;
      mark.title = `Limit ${formatDuration(day.ceiling_ms)}`;
      track.append(mark);
    }
    if (focus === null && day.devices.filter((entry) => entry.creditedMs > 0).length > 1) {
      const split = new Map(day.devices.filter((entry) => entry.creditedMs > 0).map((entry) => [entry.deviceId, entry.creditedMs]));
      setTip(track, () => [el("strong", "", `${longDayLabel(day.day)}, ${formatDuration(used)}`), ...deviceLines(split, device)]);
    }
    const label = el("span", day.day === today ? "day today" : "day", dayLabel(day.day, today));
    const value = el("span", over ? "value over" : "value", formatDuration(used));
    link.append(label, track, value, el("span", "chev", "›"));
    item.append(link);
    list.append(item);
  }
}

// ---- Day view ----

function dayFromHash() {
  const match = /^#day\/(\d{4}-\d{2}-\d{2})$/.exec(location.hash);
  return match ? match[1] : null;
}

async function loadDay() {
  const key = dayFromHash();
  const today = dayKeyIn(settings.timezone);
  const detail = await api(`/v1/days/${key}`);
  $("day-title").textContent = key === today ? "Today" : longDayLabel(key);
  const parts = [formatDuration(detail.credited_ms)];
  if (detail.ceiling_ms !== null) {
    parts.push(detail.over ? `over the ${formatDuration(detail.ceiling_ms)} limit by ${formatDuration(detail.credited_ms - detail.ceiling_ms)}` : `of a ${formatDuration(detail.ceiling_ms)} limit`);
  }
  $("day-sub").textContent = parts.join(" ");
  $("day-sub").style.color = detail.over ? "var(--over)" : "";
  $("day-prev").href = `#day/${shiftDay(key, -1)}`;
  const next = shiftDay(key, 1);
  $("day-next").href = `#day/${next}`;
  $("day-next").setAttribute("aria-disabled", String(next > today));
  renderDay($("day-detail"), detail);
}

// ---- Settings ----

function renderSettings() {
  $("set-username").textContent = settings.username;
  $("set-timezone").textContent = settings.timezone;
  $("set-idle").textContent = formatDuration(settings.idle_threshold_ms);
}

async function loadDevices() {
  const stats = await api("/v1/stats");
  const info = stats.device_info ?? [];
  const device = deviceBook(info);
  const list = $("settings-devices");
  list.replaceChildren();
  for (const entry of info) {
    const item = el("li");
    const meta = [entry.platform === "macos" ? "Mac" : entry.platform, entry.revoked ? "signed out" : ago(entry.last_upload_at_ms)];
    item.append(swatch(device(entry.device_id).color), el("span", "", entry.display_name), el("span", "meta", meta.join(", ")));
    list.append(item);
  }
  $("settings-devices-empty").hidden = info.length > 0;
}

async function saveLimit(event) {
  event.preventDefault();
  const hours = Number($("limit-hours").value);
  const minutes = Number($("limit-minutes").value);
  if (!Number.isInteger(hours) || !Number.isInteger(minutes) || hours < 0 || minutes < 0 || minutes > 59 || hours > 24) {
    $("limit-status").textContent = "Enter whole hours (0–24) and minutes (0–59).";
    return;
  }
  const limitMs = (hours * 60 + minutes) * 60_000;
  $("limit-save").disabled = true;
  try {
    await api("/v1/limits", { method: "POST", body: { limit_ms: limitMs } });
    $("limit-status").textContent = `Limit saved. Today's limit is now ${formatDuration(limitMs)}.`;
  } catch (error) {
    if (error instanceof AuthError) return handleFailure(error);
    $("limit-status").textContent = `Could not save (${error.message}).`;
  } finally {
    $("limit-save").disabled = false;
  }
}

// ---- Breaks ----

const BREAK_ERRORS = {
  bad_every_minutes: "Remind every 1 to 240 minutes.",
  bad_items: "Keep between 1 and 20 pauses.",
  bad_item_message: "Every pause needs a short message (up to 200 characters).",
  bad_item_minutes: "Each pause lasts 1 to 180 minutes.",
  bad_session_break: "The session pause needs a message and 1 to 180 minutes.",
  bad_overtime: "The past-the-limit pause needs a message, 1 to 180 minutes, and a gap of 1 to 240 minutes.",
  bad_scheduled: "Each set time needs a time, a message, and 1 to 180 minutes (up to 10 times).",
};
let breaksDirty = false;

function breakRow(item) {
  const row = el("li");
  row.dataset.id = item.id;
  const message = el("input", "msg");
  message.value = item.message;
  message.placeholder = "What this pause is for";
  message.maxLength = 200;
  message.setAttribute("aria-label", "Pause message");
  const opts = el("div", "opts");
  const minutesLabel = el("label");
  const minutes = el("input", "minutes");
  minutes.type = "number";
  minutes.min = "1";
  minutes.max = "180";
  minutes.inputMode = "numeric";
  minutes.value = String(item.minutes);
  minutesLabel.append(minutes, document.createTextNode("min"));
  const restLabel = el("label");
  const rest = el("input", "rest");
  rest.type = "checkbox";
  rest.checked = item.rest;
  restLabel.append(rest, document.createTextNode("Screen off ends it"));
  opts.append(minutesLabel, restLabel);
  const remove = el("button", "link remove", "Remove");
  remove.type = "button";
  remove.addEventListener("click", () => {
    row.remove();
    breaksDirty = true;
    syncRemoveButtons();
  });
  row.append(message, opts, remove);
  return row;
}

function syncRemoveButtons() {
  const rows = $("breaks-items").children;
  for (const row of rows) row.querySelector(".remove").disabled = rows.length <= 1;
  $("breaks-add").disabled = rows.length >= 20;
}

function scheduledRow(entry) {
  const row = el("li");
  row.dataset.id = entry.id;
  const message = el("input", "msg");
  message.value = entry.message;
  message.placeholder = "What this pause is for";
  message.maxLength = 200;
  message.setAttribute("aria-label", "Set-time pause message");
  const when = el("div", "when");
  const atLabel = el("label");
  const at = el("input", "at");
  at.type = "time";
  at.required = true;
  at.value = entry.at;
  atLabel.append(document.createTextNode("At"), at);
  const minutesLabel = el("label");
  const minutes = el("input", "minutes");
  minutes.type = "number";
  minutes.min = "1";
  minutes.max = "180";
  minutes.inputMode = "numeric";
  minutes.value = String(entry.minutes);
  minutesLabel.append(minutes, document.createTextNode("min"));
  when.append(atLabel, minutesLabel);
  const remove = el("button", "link remove", "Remove");
  remove.type = "button";
  remove.addEventListener("click", () => {
    row.remove();
    breaksDirty = true;
    syncScheduledAdd();
  });
  row.append(message, when, remove);
  return row;
}

function syncScheduledAdd() {
  $("scheduled-add").disabled = $("scheduled-items").children.length >= 10;
}

function renderRule(prefix, rule) {
  $(`${prefix}-enabled`).checked = rule.enabled;
  $(`${prefix}-message`).value = rule.message;
  $(`${prefix}-minutes`).value = String(rule.minutes);
  $(`${prefix}-rest`).checked = rule.rest;
}

function readRule(prefix) {
  return {
    enabled: $(`${prefix}-enabled`).checked,
    message: $(`${prefix}-message`).value.trim(),
    minutes: Number($(`${prefix}-minutes`).value),
    rest: $(`${prefix}-rest`).checked,
  };
}

function renderBreaks(settings) {
  $("breaks-enabled").checked = settings.enabled;
  $("breaks-detail").disabled = !settings.enabled;
  $("breaks-recurring").checked = settings.recurring_enabled !== false;
  $("breaks-every").value = String(settings.every_minutes);
  $("breaks-items").replaceChildren(...settings.items.map(breakRow));
  syncRemoveButtons();
  if (settings.session_break) renderRule("session", settings.session_break);
  if (settings.overtime) {
    renderRule("overtime", settings.overtime);
    $("overtime-every").value = String(settings.overtime.every_minutes);
  }
  $("scheduled-items").replaceChildren(...(settings.scheduled ?? []).map(scheduledRow));
  syncScheduledAdd();
  breaksDirty = false;
}

async function loadBreaks() {
  try {
    renderBreaks(await api("/v1/breaks"));
    $("breaks-status").textContent = "";
  } catch (error) {
    if (error instanceof AuthError) return handleFailure(error);
    $("breaks-status").textContent = `Could not load breaks (${error.message}).`;
  }
}

async function saveBreaks(event) {
  event.preventDefault();
  const items = [...$("breaks-items").children].map((row) => ({
    id: row.dataset.id,
    message: row.querySelector(".msg").value.trim(),
    minutes: Number(row.querySelector(".minutes").value),
    rest: row.querySelector(".rest").checked,
  }));
  const scheduled = [...$("scheduled-items").children].map((row) => ({
    id: row.dataset.id,
    at: row.querySelector(".at").value,
    message: row.querySelector(".msg").value.trim(),
    minutes: Number(row.querySelector(".minutes").value),
  }));
  const body = {
    enabled: $("breaks-enabled").checked,
    every_minutes: Number($("breaks-every").value),
    items,
    recurring_enabled: $("breaks-recurring").checked,
    session_break: readRule("session"),
    overtime: { ...readRule("overtime"), every_minutes: Number($("overtime-every").value) },
    scheduled,
  };
  $("breaks-save").disabled = true;
  try {
    renderBreaks(await api("/v1/breaks", { method: "PUT", body }));
    $("breaks-status").textContent = body.enabled ? "Breaks saved. Breaks are on." : "Breaks saved. Breaks are off.";
  } catch (error) {
    if (error instanceof AuthError) return handleFailure(error);
    $("breaks-status").textContent = BREAK_ERRORS[error.message] ?? `Could not save (${error.message}).`;
  } finally {
    $("breaks-save").disabled = false;
  }
}

// ---- Navigation and refresh ----

function currentTab() {
  if (dayFromHash()) return "day";
  const name = location.hash.slice(1);
  return TABS.includes(name) && name !== "day" ? name : "today";
}

async function refresh() {
  if (!settings) return;
  try {
    const tab = currentTab();
    if (tab === "history") await loadHistory();
    else if (tab === "day") await loadDay();
    else if (tab === "settings") await loadDevices();
    else await loadToday();
    showError("");
  } catch (error) {
    handleFailure(error);
  }
}

function showTab() {
  const tab = currentTab();
  for (const name of TABS) $(`tab-${name}`).hidden = name !== tab;
  // A single day lives under History.
  const highlighted = tab === "day" ? "history" : tab;
  for (const link of document.querySelectorAll(".tabs a")) {
    if (link.dataset.tab === highlighted) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  $("tip").hidden = true;
  if (tab === "settings" && !breaksDirty) loadBreaks();
  refresh();
}

function startRefresh() {
  stopRefresh();
  refreshTimer = setInterval(() => {
    if (document.visibilityState === "visible" && currentTab() !== "settings") refresh();
  }, REFRESH_MS);
}

function stopRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}

async function enterApp() {
  settings = await api("/v1/settings");
  renderSettings();
  $("login-view").hidden = true;
  $("app-view").hidden = false;
  showTab();
  startRefresh();
}

// ---- Login and logout ----

async function login(event) {
  event.preventDefault();
  const username = $("username").value.trim();
  const password = $("password").value;
  if (!username || !password) {
    showLogin("Enter your username and password.");
    return;
  }
  $("login-button").disabled = true;
  $("login-error").hidden = true;
  try {
    const response = await fetch("/v1/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    if (response.status === 401) return showLogin("Wrong username or password.");
    if (response.status === 429) return showLogin("Too many attempts. Wait a minute and try again.");
    if (!response.ok) return showLogin(`Login failed (HTTP ${response.status}).`);
    const data = await response.json();
    writeToken(data.session_token);
    $("password").value = "";
    await enterApp();
  } catch (error) {
    if (error instanceof AuthError) return showLogin("Login did not stick. Try again.");
    showLogin("Could not reach Workholic. Check your connection.");
  } finally {
    $("login-button").disabled = false;
  }
}

async function logout() {
  try {
    await api("/v1/logout", { method: "POST" });
  } catch {
    // The local token is dropped either way.
  }
  writeToken(null);
  focus = null;
  location.hash = "";
  showLogin();
}

// ---- Boot ----

$("login-form").addEventListener("submit", login);
$("limit-form").addEventListener("submit", saveLimit);
$("breaks-form").addEventListener("submit", saveBreaks);
$("breaks-form").addEventListener("input", () => {
  breaksDirty = true;
});
$("breaks-enabled").addEventListener("change", () => {
  $("breaks-detail").disabled = !$("breaks-enabled").checked;
});
$("breaks-add").addEventListener("click", () => {
  $("breaks-items").append(breakRow({ id: crypto.randomUUID(), message: "", minutes: 5, rest: false }));
  breaksDirty = true;
  syncRemoveButtons();
  $("breaks-items").lastElementChild.querySelector(".msg").focus();
});
$("scheduled-add").addEventListener("click", () => {
  $("scheduled-items").append(scheduledRow({ id: crypto.randomUUID(), at: "13:00", message: "Lunch. Away from the screen.", minutes: 45 }));
  breaksDirty = true;
  syncScheduledAdd();
  $("scheduled-items").lastElementChild.querySelector(".msg").focus();
});
$("logout").addEventListener("click", logout);
$("refresh").addEventListener("click", refresh);
window.addEventListener("hashchange", () => settings && showTab());
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refresh();
});

if (readToken()) {
  enterApp().catch((error) => {
    if (error instanceof AuthError) {
      writeToken(null);
      showLogin();
    } else {
      showLogin("Could not reach Workholic. Check your connection.");
    }
  });
} else {
  showLogin();
}
