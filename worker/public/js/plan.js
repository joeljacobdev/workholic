// "Your day": the account's one plan for all its Macs. A daily limit, or time blocks for weekdays and
// weekends that today can replace, and how the day ends. Nothing is stored until Save is pressed, and
// a save that would shut Macs down or cover their screens within the hour asks first.
import { $, AuthError, api, app, el, formatDuration, handleFailure, minuteOfDay, dayKeyIn, onSignOut, tellMac } from "./core.js";
import { openDialog } from "./dialog.js";

const DEFAULT_PLAN = { mode: "limit", weekdays: [], weekends: [], today: null, outside: "pause", shutdown: "off", at: null, delay_minutes: 0, command: null };
const MAX_BLOCKS = 8;
const DAY_MINUTES = 1440;
const SCRIPT_NAME = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}$/;
/** A save that would shut down or cover this many minutes from now, or sooner, asks first. */
const SOON_MINUTES = 60;
const CHECK_IN = "within 5 minutes";
const LISTS = ["weekdays", "weekends", "today"];
const SHUTDOWNS = {
  limit: [["off", "Off"], ["time", "At a set time"], ["limit", "After the daily limit"]],
  planner: [["off", "Off"], ["last_block", "When the last block ends"], ["time", "At a set time"]],
};

const ERRORS = {
  bad_plan: "The plan did not pass the server's checks. Check the blocks, the times, and the script name.",
  bad_limit: "Enter a limit between 0 and 24 hours.",
};

/** The plan and limit as last stored, with a stale "today only" left out. */
let saved = null;
/** The form holds blocks for today only. */
let todayOwn = false;
let busy = false;

onSignOut(() => {
  saved = null;
  $("plan-status").textContent = "";
});

// ---- The plan's rules, shared with Today ----

export const todayKey = () => dayKeyIn(app.settings.timezone);

export function isWeekend(key) {
  const day = new Date(`${key}T12:00:00Z`).getUTCDay();
  return day === 0 || day === 6;
}

export function blocksOn(plan, key) {
  if (plan.today?.day === key) return plan.today.blocks;
  return isWeekend(key) ? plan.weekends : plan.weekdays;
}

export const plannedMs = (blocks) => blocks.reduce((sum, [start, end]) => sum + (end - start) * 60_000, 0);

export function currentPlan() {
  return app.settings?.day_plan ?? DEFAULT_PLAN;
}

const hhmm = (minute) => `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
const endText = (minute) => (minute === DAY_MINUTES ? "midnight" : hhmm(minute));
const blockText = ([start, end]) => `${hhmm(start)}–${endText(end)}`;

/** "HH:MM" as minutes. An end of 00:00 is midnight at the end of the day. */
function minutes(text, isEnd) {
  if (!/^\d{2}:\d{2}$/.test(text)) return null;
  const [hours, mins] = text.split(":").map(Number);
  const value = hours * 60 + mins;
  return isEnd && value === 0 ? DAY_MINUTES : value;
}

function normalize(plan, key) {
  const p = { ...DEFAULT_PLAN, ...plan };
  return {
    mode: p.mode, weekdays: p.weekdays, weekends: p.weekends,
    today: p.today?.day === key ? p.today : null,
    outside: p.outside, shutdown: p.shutdown, at: p.at, delay_minutes: p.delay_minutes, command: p.command,
  };
}

/** When the plan shuts down today, as a minute, or null. */
function shutdownMinute(plan, key) {
  if (plan.shutdown === "time") return plan.at;
  if (plan.shutdown !== "last_block") return null;
  const blocks = blocksOn(plan, key);
  return blocks.length ? Math.min(blocks[blocks.length - 1][1], DAY_MINUTES - 1) : null;
}

function coversNow(plan, key) {
  if (plan.mode !== "planner" || plan.outside !== "pause") return false;
  const now = minuteOfDay();
  return !blocksOn(plan, key).some(([start, end]) => start <= now && now < end);
}

// ---- The block lists ----

function blockRow([start, end]) {
  const item = el("li", "block");
  const from = el("input");
  from.type = "time";
  from.value = hhmm(start);
  from.setAttribute("aria-label", "Starts");
  const to = el("input");
  to.type = "time";
  to.value = hhmm(end % DAY_MINUTES);
  to.setAttribute("aria-label", "Ends");
  const remove = el("button", "minus", "−");
  remove.type = "button";
  remove.setAttribute("aria-label", "Remove block");
  remove.addEventListener("click", () => {
    item.remove();
    showParts();
  });
  item.append(remove, from, el("span", "", "to"), to);
  return item;
}

function setBlocks(name, blocks) {
  $(`blocks-${name}`).replaceChildren(...blocks.map(blockRow));
}

function addBlock(name) {
  const list = $(`blocks-${name}`);
  if (list.children.length >= MAX_BLOCKS) return;
  const read = readBlocks(name);
  const last = read.ok && read.blocks.length ? read.blocks[read.blocks.length - 1][1] : null;
  const start = last === null ? 9 * 60 : Math.min(last + 60, DAY_MINUTES - 60);
  list.append(blockRow([start, Math.min(start + 120, DAY_MINUTES)]));
  list.lastElementChild.querySelector("input").focus();
  showParts();
}

const LIST_NAMES = { weekdays: "weekday", weekends: "weekend", today: "today's" };

function readBlocks(name) {
  const blocks = [];
  for (const item of $(`blocks-${name}`).children) {
    const [from, to] = item.querySelectorAll("input");
    const start = minutes(from.value, false);
    const end = minutes(to.value, true);
    if (start === null || end === null) return { ok: false, message: `Enter both times for each ${LIST_NAMES[name]} block.` };
    if (start >= end) return { ok: false, message: `A ${LIST_NAMES[name]} block ends before it starts (${from.value}–${to.value}).` };
    blocks.push([start, end]);
  }
  blocks.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < blocks.length; i++) {
    if (blocks[i][0] < blocks[i - 1][1]) return { ok: false, message: `Two ${LIST_NAMES[name]} blocks overlap: ${blockText(blocks[i - 1])} and ${blockText(blocks[i])}.` };
  }
  return { ok: true, blocks };
}

// ---- The form ----

const checked = (name) => document.querySelector(`input[name="${name}"]:checked`)?.value;

/** The plan as the server stores it, plus the limit, or a message saying what to fix. */
function read() {
  const key = todayKey();
  const mode = checked("plan-mode") ?? "limit";
  let limitMs = null;
  if (mode === "limit") {
    const hours = Number($("limit-hours").value || 0);
    const mins = Number($("limit-minutes").value || 0);
    if ($("limit-hours").value === "" && $("limit-minutes").value === "") return { ok: false, message: "Enter the daily limit." };
    if (!Number.isInteger(hours) || !Number.isInteger(mins) || hours < 0 || hours > 24 || mins < 0 || mins > 59 || hours * 60 + mins > DAY_MINUTES) {
      return { ok: false, message: "Enter whole hours (0–24) and minutes (0–59)." };
    }
    limitMs = (hours * 60 + mins) * 60_000;
  }
  const lists = {};
  for (const name of LISTS) {
    if (name === "today" && !todayOwn) continue;
    const result = readBlocks(name);
    if (!result.ok) return result;
    lists[name] = result.blocks;
  }
  const shutdown = $("plan-shutdown").value;
  let at = null;
  if (shutdown === "time") {
    at = minutes($("plan-at").value, false);
    if (at === null) return { ok: false, message: "Enter the time to shut down." };
  }
  let delay = 0;
  if (shutdown === "limit") {
    delay = Number($("plan-delay").value || 0);
    if (!Number.isInteger(delay) || delay < 0 || delay > 720) return { ok: false, message: "Wait 0 to 720 whole minutes." };
  }
  let command = null;
  if (shutdown !== "off") {
    command = $("plan-command").value.trim() || null;
    if (command !== null && (!SCRIPT_NAME.test(command) || command.includes(".."))) {
      return { ok: false, message: "A script name is letters, digits, dots, dashes, or underscores, and not a path." };
    }
  }
  const plan = {
    mode, weekdays: lists.weekdays, weekends: lists.weekends,
    today: todayOwn ? { day: key, blocks: lists.today } : null,
    outside: $("plan-outside").value, shutdown, at, delay_minutes: delay, command,
  };
  return { ok: true, plan, limitMs };
}

const keyOf = (plan, limitMs) => JSON.stringify([plan, plan.mode === "limit" ? limitMs : null]);

function edited() {
  const result = read();
  return !result.ok || keyOf(result.plan, result.limitMs) !== keyOf(saved.plan, saved.limitMs);
}

function fill() {
  const { plan, limitMs } = saved;
  $(`plan-mode-${plan.mode}`).checked = true;
  if (limitMs != null) {
    const total = Math.round(limitMs / 60_000);
    $("limit-hours").value = String(Math.floor(total / 60));
    $("limit-minutes").value = String(total % 60);
  } else {
    $("limit-hours").value = $("limit-minutes").value = "";
  }
  setBlocks("weekdays", plan.weekdays);
  setBlocks("weekends", plan.weekends);
  todayOwn = plan.today !== null;
  setBlocks("today", plan.today?.blocks ?? []);
  $("plan-outside").value = plan.outside;
  setShutdownOptions(plan.mode);
  $("plan-shutdown").value = plan.shutdown;
  $("plan-at").value = hhmm(plan.at ?? 22 * 60);
  $("plan-delay").value = String(plan.delay_minutes);
  $("plan-command").value = plan.command ?? "";
}

/** The shutdown choices that belong to a mode. One that does not carry over becomes "Off". */
function setShutdownOptions(mode) {
  const select = $("plan-shutdown");
  if (select.dataset.mode === mode) return;
  const before = select.value;
  select.dataset.mode = mode;
  select.replaceChildren(...SHUTDOWNS[mode].map(([value, label]) => {
    const option = el("option", "", label);
    option.value = value;
    return option;
  }));
  select.value = SHUTDOWNS[mode].some(([value]) => value === before) ? before : "off";
}

/** The last-block choice says when that is today, so the shutdown time is plain without a note. */
function labelLastBlock(plan, key) {
  const option = [...$("plan-shutdown").options].find((entry) => entry.value === "last_block");
  if (!option) return;
  const at = plan ? shutdownMinute({ ...plan, shutdown: "last_block" }, key) : null;
  option.textContent = plan && at === null ? "When the last block ends (none today)"
    : at === null ? "When the last block ends" : `When the last block ends (${hhmm(at)} today)`;
}

function showParts() {
  const mode = checked("plan-mode") ?? "limit";
  const key = todayKey();
  $("plan-limit").hidden = mode !== "limit";
  $("plan-planner").hidden = mode !== "planner";
  setShutdownOptions(mode);
  const shutdown = $("plan-shutdown").value;
  $("plan-at-row").hidden = shutdown !== "time";
  $("plan-delay-row").hidden = shutdown !== "limit";
  $("plan-script-row").hidden = shutdown === "off";
  $("blocks-today").hidden = $("today-add").hidden = $("today-reset").hidden = !todayOwn;
  $("today-change").hidden = todayOwn;
  for (const name of LISTS) {
    const add = document.querySelector(`[data-add="${name}"]`);
    if (add) add.disabled = $(`blocks-${name}`).children.length >= MAX_BLOCKS;
  }
  const result = read();
  if (mode === "planner") labelLastBlock(result.ok ? result.plan : null, key);
  // Only a problem with what is entered is spelled out; the form itself says what the plan does.
  $("plan-problem").textContent = result.ok ? "" : result.message;
  $("plan-problem").hidden = result.ok;
  const changed = saved !== null && edited();
  $("plan-save").disabled = busy || !changed;
  $("plan-discard").hidden = !changed;
}

/** What saving would set off within the hour, in words. Empty when nothing soon. */
async function soonWarnings(plan, limitMs, key) {
  const warnings = [];
  const at = shutdownMinute(plan, key);
  if (at !== null && at !== shutdownMinute(saved.plan, key)) {
    const until = at - minuteOfDay();
    if (until > 0 && until <= SOON_MINUTES) {
      warnings.push(`Your Macs shut down today at ${hhmm(at)}, in ${formatDuration(until * 60_000)}. Each warns for 60 seconds first, with Cancel.`);
    }
  }
  const limitChanged = plan.shutdown === "limit" &&
    (saved.plan.shutdown !== "limit" || saved.limitMs !== limitMs || saved.plan.delay_minutes !== plan.delay_minutes);
  if (limitChanged) {
    const detail = await api(`/v1/days/${key}`);
    if (detail.credited_ms >= limitMs) {
      warnings.push(`Today's total, ${formatDuration(detail.credited_ms)}, is already past ${formatDuration(limitMs)}. Your Macs shut down ${plan.delay_minutes > 0 ? `${formatDuration(plan.delay_minutes * 60_000)} after crossing it` : CHECK_IN}, each with a 60-second warning.`);
    }
  }
  if (coversNow(plan, key) && !coversNow(saved.plan, key)) {
    warnings.push(`It is outside your blocks now, so your Macs cover their screens ${CHECK_IN}.`);
  }
  return warnings;
}

async function save(event) {
  event.preventDefault();
  const status = $("plan-status");
  const result = read();
  if (!result.ok) {
    status.textContent = result.message;
    return;
  }
  const key = todayKey();
  busy = true;
  showParts();
  try {
    const warnings = await soonWarnings(result.plan, result.limitMs, key);
    if (warnings.length && !(await openDialog({ title: "Save this plan?", body: warnings, confirmLabel: "Save", danger: true }))) return;
    status.textContent = "Saving…";
    const body = { plan: result.plan };
    if (result.plan.mode === "limit") body.limit_ms = result.limitMs;
    const answer = await api("/v1/day-plan", { method: "PUT", body });
    app.settings.day_plan = answer.day_plan;
    app.settings.day_plan_updated_at_ms = answer.day_plan_updated_at_ms;
    app.settings.limit_ms = answer.limit_ms;
    saved = { plan: normalize(answer.day_plan, key), limitMs: answer.limit_ms };
    fill();
    status.textContent = "Saved";
    tellMac("saved");
  } catch (error) {
    if (error instanceof AuthError) return handleFailure(error);
    status.textContent = ERRORS[error.message] ?? `Could not save (${error.message}).`;
  } finally {
    busy = false;
    showParts();
  }
}

/** Brings the panel up to date without touching an edit in progress. */
export function renderPlan() {
  if (!app.settings || busy) return;
  const key = todayKey();
  const next = { plan: normalize(currentPlan(), key), limitMs: app.settings.limit_ms };
  if (saved === null || !edited()) {
    saved = next;
    fill();
  } else if (keyOf(next.plan, next.limitMs) !== keyOf(saved.plan, saved.limitMs)) {
    saved = next;
    $("plan-status").textContent = "The plan was changed elsewhere. Saving replaces that with what is here.";
  }
  showParts();
}

export function initPlan() {
  const form = $("plan-form");
  form.addEventListener("submit", save);
  form.addEventListener("input", showParts);
  form.addEventListener("change", showParts);
  for (const button of form.querySelectorAll("[data-add]")) {
    button.addEventListener("click", () => addBlock(button.dataset.add));
  }
  $("today-change").addEventListener("click", () => {
    todayOwn = true;
    const plan = read().plan ?? saved.plan;
    setBlocks("today", isWeekend(todayKey()) ? plan.weekends ?? [] : plan.weekdays ?? []);
    showParts();
  });
  $("today-reset").addEventListener("click", () => {
    todayOwn = false;
    setBlocks("today", []);
    showParts();
  });
  $("plan-discard").addEventListener("click", () => {
    fill();
    $("plan-status").textContent = "";
    showParts();
  });
}
