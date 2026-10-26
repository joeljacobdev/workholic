// What every part of the page shares: the account, the API, formatting, and signing out.

const TOKEN_KEY = "workholic.session";
export const TABS = ["today", "history", "day", "settings"];
/** The one cadence for everything the page shows: the open tab is fetched again this often while visible. */
export const SYNC_MS = 60_000;
export const HOUR_MS = 3_600_000;
const DEVICE_SLOTS = 5;
export const ALL_COLOR = "var(--all)";

export const $ = (id) => document.getElementById(id);

/** The signed-in account's `/v1/settings`, or null while signed out. */
export const app = { settings: null };

export class AuthError extends Error {}

export function readToken() {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function writeToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    // Private mode: the session lasts until the tab closes.
  }
}

export async function api(path, { method = "GET", body } = {}) {
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

export function formatDuration(ms) {
  const minutes = Math.round(Math.max(0, ms) / 60_000);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

export function dayKeyIn(timeZone, date = new Date()) {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

/** Minutes past midnight in the account's time zone, which is what a Mac's own clock reads. */
export function minuteOfDay(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-GB", { timeZone: app.settings.timezone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date);
  const value = (type) => Number(parts.find((part) => part.type === type)?.value ?? 0);
  return value("hour") * 60 + value("minute");
}

export function shiftDay(key, delta) {
  const date = new Date(`${key}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
}

export function dayLabel(key, todayKey) {
  if (key === todayKey) return "Today";
  if (key === shiftDay(todayKey, -1)) return "Yesterday";
  return new Intl.DateTimeFormat(undefined, { timeZone: "UTC", weekday: "short", day: "numeric" }).format(new Date(`${key}T12:00:00Z`));
}

export function longDayLabel(key) {
  return new Intl.DateTimeFormat(undefined, { timeZone: "UTC", weekday: "long", month: "long", day: "numeric" }).format(new Date(`${key}T12:00:00Z`));
}

export function clock(ms) {
  return new Intl.DateTimeFormat(undefined, { timeZone: app.settings.timezone, hour: "numeric", minute: "2-digit" }).format(new Date(ms));
}

export function hourLabel(ms) {
  return new Intl.DateTimeFormat(undefined, { timeZone: app.settings.timezone, hour: "numeric" }).format(new Date(ms));
}

export function ago(ms) {
  if (ms == null) return "never synced";
  const minutes = Math.round((Date.now() - ms) / 60_000);
  if (minutes < 2) return "synced just now";
  if (minutes < 60) return `synced ${minutes} min ago`;
  if (minutes < 48 * 60) return `synced ${Math.round(minutes / 60)} h ago`;
  return `synced ${Math.round(minutes / 1440)} days ago`;
}

export function appName(key) {
  if (key === "unattributed") return "Unattributed";
  const last = key.includes(".") ? key.slice(key.lastIndexOf(".") + 1) : key;
  return last.charAt(0).toUpperCase() + last.slice(1);
}

export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// ---- Device identity ----
// A device keeps the color of its enrollment order, so it looks the same on every day.

export function deviceBook(info) {
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

export function swatch(color) {
  const node = el("span", "swatch");
  node.style.setProperty("--c", color);
  return node;
}

// ---- Where the page is ----

export function dayFromHash() {
  const match = /^#day\/(\d{4}-\d{2}-\d{2})$/.exec(location.hash);
  return match ? match[1] : null;
}

export function currentTab() {
  if (dayFromHash()) return "day";
  const name = location.hash.slice(1);
  return TABS.includes(name) && name !== "day" ? name : "today";
}

// ---- Inside the Mac app ----
// The Mac app shows this same page in its own window, already logged in.

export const macBridge = window.webkit?.messageHandlers?.workholic ?? null;

export function tellMac(action, value) {
  macBridge?.postMessage({ action, value });
}

// ---- Errors and signing out ----

const signOutSteps = [];

/** Something to forget when the page goes back to the login screen. */
export function onSignOut(step) {
  signOutSteps.push(step);
}

export function showError(message) {
  $("app-error").textContent = message;
  $("app-error").hidden = !message;
}

export function showLogin(message) {
  for (const step of signOutSteps) step();
  app.settings = null;
  $("app-view").hidden = true;
  $("login-view").hidden = false;
  $("login-error").textContent = message ?? "";
  $("login-error").hidden = !message;
  $("username").focus();
}

export function handleFailure(error) {
  if (error instanceof AuthError) {
    writeToken(null);
    // In the Mac app the session is the Mac's. It logs out and closes this window.
    if (macBridge) return tellMac("logOut");
    showLogin("Your session ended. Log in again.");
    return;
  }
  showError(navigator.onLine ? `Could not reach Workholic (${error.message}).` : "You are offline. Showing the last numbers loaded.");
}
