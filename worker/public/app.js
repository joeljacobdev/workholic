"use strict";

const TOKEN_KEY = "workholic.session";
const TABS = ["today", "history", "settings"];
const GAUGE_CIRCUMFERENCE = 2 * Math.PI * 50;
const REFRESH_MS = 60_000;

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
  return new Intl.DateTimeFormat(undefined, { timeZone: "UTC", weekday: "short", day: "numeric" }).format(new Date(`${key}T12:00:00Z`));
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

// ---- Today ----

async function loadToday() {
  const stats = await api("/v1/stats");
  const day = stats.days[0];
  const used = day.credited_ms;
  const limit = day.ceiling_ms;
  const over = limit !== null && used > limit;

  $("today-used").textContent = formatDuration(used);
  $("today-of").textContent = limit === null ? "No daily limit set" : `of ${formatDuration(limit)}`;
  const fraction = limit ? Math.min(used / limit, 1) : 0;
  const arc = $("gauge-arc");
  arc.style.strokeDasharray = String(GAUGE_CIRCUMFERENCE);
  arc.style.strokeDashoffset = String(GAUGE_CIRCUMFERENCE * (1 - fraction));
  arc.classList.toggle("over", over);

  $("today-left").textContent = limit === null ? "–" : over ? `Over by ${formatDuration(used - limit)}` : formatDuration(limit - used);
  $("today-left").style.color = over ? "var(--over)" : "";
  $("today-limit").textContent = limit === null ? "Not set" : formatDuration(limit);
  $("today-devices").textContent = String(day.devices.length);

  const apps = [...day.apps].sort((a, b) => b.creditedMs - a.creditedMs).slice(0, 8);
  const list = $("today-apps");
  list.replaceChildren();
  const top = apps[0]?.creditedMs ?? 1;
  for (const app of apps) {
    const item = el("li");
    const label = el("div", "label");
    const name = el("span", "name", appName(app.appKey));
    name.title = app.appKey;
    label.append(name, el("span", "muted", formatDuration(app.creditedMs)));
    const meter = el("div", "meter");
    const fill = el("span");
    fill.style.width = `${Math.max(2, (app.creditedMs / top) * 100)}%`;
    meter.append(fill);
    item.append(label, meter);
    list.append(item);
  }
  $("today-apps-empty").hidden = apps.length > 0;

  if (limit !== null && document.activeElement?.closest("#limit-form") == null) {
    const minutes = Math.round(limit / 60_000);
    $("limit-hours").value = String(Math.floor(minutes / 60));
    $("limit-minutes").value = String(minutes % 60);
  }
  $("updated-at").textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// ---- History ----

async function loadHistory() {
  const today = dayKeyIn(settings.timezone);
  const from = shiftDay(today, -13);
  const stats = await api(`/v1/stats?from=${from}&to=${today}`);
  const days = [...stats.days].reverse();
  const scale = Math.max(3_600_000, ...days.map((d) => Math.max(d.credited_ms, d.ceiling_ms ?? 0)));
  const list = $("history-list");
  list.replaceChildren();
  for (const day of days) {
    const item = el("li");
    const meter = el("div", "meter");
    const fill = el("span");
    fill.style.width = `${(day.credited_ms / scale) * 100}%`;
    if (day.over) fill.classList.add("over");
    meter.append(fill);
    if (day.ceiling_ms !== null) {
      const mark = el("i");
      mark.style.left = `${(day.ceiling_ms / scale) * 100}%`;
      mark.title = `Limit ${formatDuration(day.ceiling_ms)}`;
      meter.append(mark);
    }
    item.append(el("span", "day", dayLabel(day.day, today)), meter, el("span", "value", formatDuration(day.credited_ms)));
    list.append(item);
  }
}

// ---- Settings ----

function renderSettings() {
  $("who").textContent = settings.username;
  $("set-username").textContent = settings.username;
  $("set-timezone").textContent = settings.timezone;
  $("set-idle").textContent = formatDuration(settings.idle_threshold_ms);
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
    $("limit-status").textContent = `Saved. Today's limit is now ${formatDuration(limitMs)}.`;
    await loadToday();
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

function renderBreaks(settings) {
  $("breaks-enabled").checked = settings.enabled;
  $("breaks-detail").disabled = !settings.enabled;
  $("breaks-every").value = String(settings.every_minutes);
  $("breaks-items").replaceChildren(...settings.items.map(breakRow));
  syncRemoveButtons();
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
  const body = { enabled: $("breaks-enabled").checked, every_minutes: Number($("breaks-every").value), items };
  $("breaks-save").disabled = true;
  try {
    renderBreaks(await api("/v1/breaks", { method: "PUT", body }));
    $("breaks-status").textContent = body.enabled ? "Saved. Breaks are on." : "Saved. Breaks are off.";
  } catch (error) {
    if (error instanceof AuthError) return handleFailure(error);
    $("breaks-status").textContent = BREAK_ERRORS[error.message] ?? `Could not save (${error.message}).`;
  } finally {
    $("breaks-save").disabled = false;
  }
}

// ---- Navigation and refresh ----

function currentTab() {
  const name = location.hash.slice(1);
  return TABS.includes(name) ? name : "today";
}

async function refresh() {
  if (!settings) return;
  try {
    const tab = currentTab();
    if (tab === "history") await loadHistory();
    else await loadToday();
    showError("");
  } catch (error) {
    handleFailure(error);
  }
}

function showTab() {
  const tab = currentTab();
  for (const name of TABS) $(`tab-${name}`).hidden = name !== tab;
  for (const link of document.querySelectorAll(".tabs a")) {
    if (link.dataset.tab === tab) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  if (tab === "settings" && !breaksDirty) loadBreaks();
  refresh();
}

function startRefresh() {
  stopRefresh();
  refreshTimer = setInterval(() => {
    if (document.visibilityState === "visible") refresh();
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
