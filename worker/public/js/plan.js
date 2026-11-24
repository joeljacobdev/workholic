// "Your day": the account's one plan for all its Macs. Time blocks on chosen dates; every other day
// follows the daily limit. Then how the day ends: one shutdown for every Mac, or each Mac's own.
// Nothing is stored until Save is pressed, and a save that would shut Macs down or cover their
// screens within the hour asks first.
import { $, AuthError, api, app, el, formatDuration, handleFailure, minuteOfDay, dayKeyIn, onSignOut, tellMac } from "./core.js";
import { openDialog } from "./dialog.js";

const OFF = { shutdown: "off", at: null, delay_minutes: 0, command: null };
/** The past-the-limit pause until the account says otherwise. */
const DEFAULT_OVERTIME = { enabled: false, every_minutes: 25, message: "You have crossed your limit. Try to wind down the work.", minutes: 5, rest: true };
const MAX_BLOCKS = 8;
const MAX_DATES = 60;
const DAY_MINUTES = 1440;
const SCRIPT_NAME = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}$/;
/** A save that would shut down or cover this many minutes from now, or sooner, asks first. */
const SOON_MINUTES = 60;
const CHECK_IN = "within 5 minutes";
const PLAN_END_LABEL = "After the blocks or the limit";
const SHUTDOWNS = [["off", "Off"], ["plan_end", PLAN_END_LABEL], ["time", "At a set time"]];

const ERRORS = {
  bad_plan: "The plan did not pass the server's checks. Check the blocks, the times, and the script name.",
  too_many_dates: "Too many dates.",
  bad_limit: "Enter a limit between 0 and 24 hours.",
  bad_overtime: "The reminder needs a message, 1 to 180 minutes, and a gap of 1 to 240 minutes.",
};

/** The plan, limit, and past-the-limit pause as last stored. */
let saved = null;
let busy = false;
/** The account's Macs, as the device list last fetched them, and the row each has under "each its own way". */
let macs = [];
const macRows = new Map();

onSignOut(() => {
  saved = null;
  macs = [];
  macRows.clear();
  $("plan-each").replaceChildren();
  $("plan-status").textContent = "";
});

// ---- The plan's rules, shared with Today ----

export const todayKey = () => dayKeyIn(app.settings.timezone);

/** The blocks of a block date, or none: that day follows the daily limit. */
export function blocksOn(plan, key) {
  return plan.dates.find((entry) => entry.day === key)?.blocks ?? [];
}

export const plannedMs = (blocks) => blocks.reduce((sum, [start, end]) => sum + (end - start) * 60_000, 0);

/** The plan as the server sent it with the settings; the server fills in its default until one is saved. */
export function currentPlan() {
  return app.settings.day_plan;
}

/** "Tue, 1 Dec" for a "YYYY-MM-DD" day, the same on every clock. */
const dateText = (key) => new Date(`${key}T12:00:00Z`).toLocaleDateString([], { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });

function nextDay(key) {
  const date = new Date(`${key}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
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

/** The plan's fields in the order `read` builds them, so the two compare as text. */
function normalize(p) {
  return {
    dates: p.dates, outside: p.outside, shutdown: p.shutdown, at: p.at, delay_minutes: p.delay_minutes, command: p.command,
    scope: p.scope, each: p.each,
  };
}

/** How one Mac shuts down under the plan: the plan's own way, or its entry, or not at all. */
function shutdownOf(plan, deviceId) {
  if (plan.scope !== "each") return { shutdown: plan.shutdown, at: plan.at, delay_minutes: plan.delay_minutes, command: plan.command };
  return plan.each[deviceId] ?? OFF;
}

/** When the plan shuts a Mac down today, as a minute, or null. */
function shutdownMinute(plan, key, deviceId) {
  const own = shutdownOf(plan, deviceId);
  if (own.shutdown === "time") return own.at;
  if (own.shutdown !== "plan_end") return null;
  const blocks = blocksOn(plan, key);
  return blocks.length ? Math.min(blocks[blocks.length - 1][1], DAY_MINUTES - 1) : null;
}

/** On a block date with "Cover the screen", outside the blocks covers. Other days follow the limit. */
function coversNow(plan, key) {
  const blocks = blocksOn(plan, key);
  if (plan.outside !== "pause" || blocks.length === 0) return false;
  const now = minuteOfDay();
  return !blocks.some(([start, end]) => start <= now && now < end);
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

function setBlocks(list, blocks) {
  list.replaceChildren(...blocks.map(blockRow));
}

function addBlock(list, label) {
  if (list.children.length >= MAX_BLOCKS) return;
  const read = readBlocks(list, label);
  const last = read.ok && read.blocks.length ? read.blocks[read.blocks.length - 1][1] : null;
  const start = last === null ? 9 * 60 : Math.min(last + 60, DAY_MINUTES - 60);
  list.append(blockRow([start, Math.min(start + 120, DAY_MINUTES)]));
  list.lastElementChild.querySelector("input").focus();
  showParts();
}

/** One list's blocks, in order, or a message naming the date (`label`) and what to fix. */
function readBlocks(list, label) {
  const blocks = [];
  for (const item of list.children) {
    const [from, to] = item.querySelectorAll("input");
    const start = minutes(from.value, false);
    const end = minutes(to.value, true);
    if (start === null || end === null) return { ok: false, message: `Enter both times for each block on ${label}.` };
    if (start >= end) return { ok: false, message: `A block on ${label} ends before it starts (${from.value}–${to.value}).` };
    blocks.push([start, end]);
  }
  blocks.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < blocks.length; i++) {
    if (blocks[i][0] < blocks[i - 1][1]) return { ok: false, message: `Two blocks on ${label} overlap: ${blockText(blocks[i - 1])} and ${blockText(blocks[i])}.` };
  }
  return { ok: true, blocks };
}

// ---- The dates ----

/** One date with its blocks: the date, "Remove date", the block list, and "Add block". */
function dateRow(day, blocks) {
  const item = el("div", "cell stacked");
  const date = el("input");
  date.type = "date";
  date.value = day;
  date.setAttribute("aria-label", "Date");
  const remove = el("button", "btn", "Remove date");
  remove.type = "button";
  remove.addEventListener("click", () => {
    item.remove();
    showParts();
  });
  const head = el("div", "cell-row");
  head.append(date, remove);
  const list = el("ol", "blocks");
  setBlocks(list, blocks);
  const add = el("button", "add", "Add block");
  add.type = "button";
  add.addEventListener("click", () => addBlock(list, dateText(date.value || todayKey())));
  item.append(head, list, add);
  return item;
}

const dateRows = () => [...$("plan-dates").children];
const rowDay = (row) => row.querySelector('input[type="date"]').value;

function setDates(dates) {
  $("plan-dates").replaceChildren(...dates.map(({ day, blocks }) => dateRow(day, blocks)));
}

/** A new date opens on today, or the day after the last one entered, with one block to start from. */
function addDate() {
  if (dateRows().length >= MAX_DATES) return;
  const days = new Set(dateRows().map(rowDay));
  let day = todayKey();
  while (days.has(day)) day = nextDay(day);
  const row = dateRow(day, []);
  const after = dateRows().find((other) => rowDay(other) > day) ?? null;
  $("plan-dates").insertBefore(row, after);
  addBlock(row.querySelector("ol"), dateText(day));
}

/** The dates as the server stores them, soonest first, or a message saying what to fix. */
function readDates() {
  const dates = [];
  for (const row of dateRows()) {
    const day = rowDay(row);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return { ok: false, message: "Enter each date." };
    const label = dateText(day);
    if (dates.some((entry) => entry.day === day)) return { ok: false, message: `${label} is entered twice.` };
    const result = readBlocks(row.querySelector("ol"), label);
    if (!result.ok) return result;
    if (result.blocks.length === 0) return { ok: false, message: `Add a block on ${label}, or remove the date.` };
    dates.push({ day, blocks: result.blocks });
  }
  dates.sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));
  return { ok: true, dates };
}

// ---- The form ----

/**
 * The plan as the server stores it, plus the limit and the past-the-limit pause, or a message saying
 * what to fix. A blank limit keeps the stored one.
 */
function read() {
  let limitMs = saved?.limitMs ?? null;
  if ($("limit-hours").value !== "" || $("limit-minutes").value !== "") {
    const hours = Number($("limit-hours").value || 0);
    const mins = Number($("limit-minutes").value || 0);
    if (!Number.isInteger(hours) || !Number.isInteger(mins) || hours < 0 || hours > 24 || mins < 0 || mins > 59 || hours * 60 + mins > DAY_MINUTES) {
      return { ok: false, message: "Enter whole hours (0–24) and minutes (0–59)." };
    }
    limitMs = (hours * 60 + mins) * 60_000;
  }
  const overtimeResult = readOvertime(saved?.overtime ?? DEFAULT_OVERTIME);
  if (!overtimeResult.ok) return overtimeResult;
  const overtime = overtimeResult.overtime;
  const datesResult = readDates();
  if (!datesResult.ok) return datesResult;
  const scope = $("plan-scope").value;
  let own = OFF;
  const each = {};
  if (scope === "all") {
    const result = readShutdown({ when: $("plan-shutdown"), at: $("plan-at"), delay: $("plan-delay"), command: $("plan-command") }, "");
    if (!result.ok) return result;
    own = result.shutdown;
  } else {
    // A Mac with no row (signed out, or gone) keeps its entry, so an old entry alone does not read as an edit.
    const known = new Set(macs.map((mac) => mac.device_id));
    for (const [id, entry] of Object.entries(saved?.plan.each ?? {})) {
      if (!known.has(id)) each[id] = entry;
    }
    for (const mac of macs) {
      const row = macRows.get(mac.device_id);
      if (!row) continue;
      const result = readShutdown(row.fields, `${mac.display_name}: `);
      if (!result.ok) return result;
      if (result.shutdown.shutdown !== "off") each[mac.device_id] = result.shutdown;
    }
  }
  const plan = { dates: datesResult.dates, outside: $("plan-outside").value, ...own, scope, each };
  return { ok: true, plan, limitMs, overtime };
}

/** The past-the-limit pause from its controls. Turned off, it keeps what was stored, as the fields are hidden. */
function readOvertime(stored) {
  if (!$("overtime-enabled").checked) return { ok: true, overtime: { ...stored, enabled: false } };
  const every = Number($("overtime-every").value);
  const minutes = Number($("overtime-minutes").value);
  const message = $("overtime-message").value.trim();
  if (!Number.isInteger(every) || every < 1 || every > 240) return { ok: false, message: "Remind again every 1 to 240 whole minutes." };
  if (message === "") return { ok: false, message: "Enter what the reminder says." };
  if (!Number.isInteger(minutes) || minutes < 1 || minutes > 180) return { ok: false, message: "The reminder lasts 1 to 180 whole minutes." };
  return { ok: true, overtime: { enabled: true, every_minutes: every, message, minutes, rest: $("overtime-rest").checked } };
}

/** One shutdown's four fields from its controls, or a message saying what to fix, with `who` in front. */
function readShutdown(fields, who) {
  const shutdown = fields.when.value;
  let at = null;
  if (shutdown === "time") {
    at = minutes(fields.at.value, false);
    if (at === null) return { ok: false, message: `${who}Enter the time to shut down.` };
  }
  let delay = 0;
  if (shutdown === "plan_end") {
    delay = Number(fields.delay.value || 0);
    if (!Number.isInteger(delay) || delay < 0 || delay > 720) return { ok: false, message: `${who}Wait 0 to 720 whole minutes.` };
  }
  let command = null;
  if (shutdown !== "off") {
    command = fields.command.value.trim() || null;
    if (command !== null && (!SCRIPT_NAME.test(command) || command.includes(".."))) {
      return { ok: false, message: `${who}A script name is letters, digits, dots, dashes, or underscores, and not a path.` };
    }
  }
  return { ok: true, shutdown: { shutdown, at, delay_minutes: delay, command } };
}

/** Entries per Mac compare by device id, whatever order they came in. */
const keyOf = (plan, limitMs, overtime) => JSON.stringify([
  { ...plan, each: Object.fromEntries(Object.entries(plan.each ?? {}).sort()) },
  limitMs,
  overtimeKey(overtime),
]);
const overtimeKey = (o) => [o.enabled, o.every_minutes, o.message, o.minutes, o.rest];

function edited() {
  const result = read();
  return !result.ok || keyOf(result.plan, result.limitMs, result.overtime) !== keyOf(saved.plan, saved.limitMs, saved.overtime);
}

function fill() {
  const { plan, limitMs, overtime } = saved;
  $("overtime-enabled").checked = overtime.enabled;
  $("overtime-every").value = String(overtime.every_minutes);
  $("overtime-message").value = overtime.message;
  $("overtime-minutes").value = String(overtime.minutes);
  $("overtime-rest").checked = overtime.rest;
  if (limitMs != null) {
    const total = Math.round(limitMs / 60_000);
    $("limit-hours").value = String(Math.floor(total / 60));
    $("limit-minutes").value = String(total % 60);
  } else {
    $("limit-hours").value = $("limit-minutes").value = "";
  }
  setDates(plan.dates);
  $("plan-outside").value = plan.outside;
  $("plan-scope").value = plan.scope;
  fillShutdown({ when: $("plan-shutdown"), at: $("plan-at"), delay: $("plan-delay"), command: $("plan-command") }, plan);
  for (const [id, row] of macRows) fillShutdown(row.fields, plan.each[id] ?? OFF);
}

function fillShutdown(fields, own) {
  setShutdownOptions(fields.when);
  fields.when.value = own.shutdown;
  fields.at.value = hhmm(own.at ?? 22 * 60);
  fields.delay.value = String(own.delay_minutes);
  fields.command.value = own.command ?? "";
}

// ---- One row per Mac ----

/** The Macs the rows are for, from the device list. Rows already there keep what is typed in them. */
export function setPlanDevices(info) {
  const thisMac = window.workholicMacState?.deviceId ?? null;
  // This Mac first, inside the app; the rest in enrollment order.
  macs = [...info].sort((a, b) => (b.device_id === thisMac) - (a.device_id === thisMac));
  const list = $("plan-each");
  const present = new Set();
  macs.forEach((mac, index) => {
    present.add(mac.device_id);
    let row = macRows.get(mac.device_id);
    if (!row) {
      row = macRow(mac.device_id);
      macRows.set(mac.device_id, row);
      fillShutdown(row.fields, saved?.plan.each[mac.device_id] ?? OFF);
    }
    row.name.textContent = mac.display_name;
    row.mine.hidden = mac.device_id !== thisMac;
    if (list.children[index] !== row.item) list.insertBefore(row.item, list.children[index] ?? null);
  });
  for (const [id, row] of macRows) {
    if (present.has(id)) continue;
    row.item.remove();
    macRows.delete(id);
  }
  showParts();
}

function macRow(deviceId) {
  const item = el("div", "cell stacked mac-shutdown");
  item.dataset.device = deviceId;
  const name = el("strong");
  const mine = el("small", "", "this Mac");
  mine.hidden = true;
  const label = el("span", "cell-label");
  label.append(name, mine);
  const when = el("select");
  when.setAttribute("aria-label", "When to shut down");
  const head = el("div", "cell-row");
  head.append(label, when);
  const at = el("input");
  at.type = "time";
  at.setAttribute("aria-label", "Shutdown time");
  const delay = el("input", "num-field");
  delay.type = "number";
  delay.min = "0";
  delay.max = "720";
  delay.step = "5";
  delay.inputMode = "numeric";
  delay.setAttribute("aria-label", "Minutes to wait");
  const delayFields = el("span", "fields");
  delayFields.append(delay, " min");
  const command = el("input", "text-field");
  command.type = "text";
  command.placeholder = "None";
  command.spellcheck = false;
  command.autocapitalize = "off";
  command.setAttribute("aria-label", "Script file name");
  const line = (text, control) => {
    const row = el("div", "cell-row");
    row.append(el("span", "", text), control);
    return row;
  };
  const rows = { at: line("Time", at), delay: line("Wait after the limit", delayFields), script: line("Script", command) };
  item.append(head, rows.at, rows.delay, rows.script);
  return { item, name, mine, rows, fields: { when, at, delay, command } };
}

/** The shutdown choices, filled in once per list. */
function setShutdownOptions(select) {
  if (select.options.length) return;
  select.replaceChildren(...SHUTDOWNS.map(([value, label]) => {
    const option = el("option", "", label);
    option.value = value;
    return option;
  }));
}

/** The choice that follows the day says what that is today, so the shutdown time is plain without a note. */
function labelPlanEnd(plan, key, select) {
  const option = [...select.options].find((entry) => entry.value === "plan_end");
  if (!option) return;
  const at = plan ? shutdownMinute({ ...plan, scope: "all", shutdown: "plan_end" }, key) : null;
  option.textContent = at === null ? PLAN_END_LABEL : `${PLAN_END_LABEL} (${hhmm(at)})`;
}

function showParts() {
  const key = todayKey();
  $("plan-over-detail").hidden = !$("overtime-enabled").checked;
  const scope = $("plan-scope").value;
  $("plan-shared").hidden = scope !== "all";
  $("plan-each").hidden = scope !== "each";
  $("plan-each-empty").hidden = scope !== "each" || macs.length > 0;
  setShutdownOptions($("plan-shutdown"));
  const shutdown = $("plan-shutdown").value;
  $("plan-at-row").hidden = shutdown !== "time";
  $("plan-delay-row").hidden = shutdown !== "plan_end";
  $("plan-script-row").hidden = shutdown === "off";
  for (const row of macRows.values()) {
    setShutdownOptions(row.fields.when);
    const own = row.fields.when.value;
    row.rows.at.hidden = own !== "time";
    row.rows.delay.hidden = own !== "plan_end";
    row.rows.script.hidden = own === "off";
  }
  for (const row of dateRows()) row.querySelector(".add").disabled = row.querySelector("ol").children.length >= MAX_BLOCKS;
  $("date-add").disabled = dateRows().length >= MAX_DATES;
  const result = read();
  labelPlanEnd(result.ok ? result.plan : null, key, $("plan-shutdown"));
  for (const row of macRows.values()) labelPlanEnd(result.ok ? result.plan : null, key, row.fields.when);
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
  // Under "each its own way", every Mac is looked at by name; under "all", once for all of them.
  const who = plan.scope === "each" ? macs.map((mac) => ({ id: mac.device_id, name: mac.display_name })) : [{ id: undefined, name: "Your Macs" }];
  const soon = new Map();
  for (const mac of who) {
    const at = shutdownMinute(plan, key, mac.id);
    if (at === null || at === shutdownMinute(saved.plan, key, mac.id)) continue;
    const until = at - minuteOfDay();
    if (until > 0 && until <= SOON_MINUTES) soon.set(at, [...(soon.get(at) ?? []), mac.name]);
  }
  for (const [at, names] of soon) {
    const verb = plan.scope === "each" && names.length === 1 ? "shuts" : "shut";
    warnings.push(`${names.join(", ")} ${verb} down today at ${hhmm(at)}, in ${formatDuration((at - minuteOfDay()) * 60_000)}. Each warns for 60 seconds first, with Cancel.`);
  }
  // After the limit applies only on a day without blocks.
  const byLimit = (p, own) => own.shutdown === "plan_end" && blocksOn(p, key).length === 0;
  const afterLimit = limitMs === null ? [] : who.filter((mac) => {
    const own = shutdownOf(plan, mac.id);
    const before = shutdownOf(saved.plan, mac.id);
    return byLimit(plan, own) && (!byLimit(saved.plan, before) || saved.limitMs !== limitMs || before.delay_minutes !== own.delay_minutes);
  });
  if (afterLimit.length) {
    const detail = await api(`/v1/days/${key}`);
    if (detail.credited_ms >= limitMs) {
      const names = afterLimit.map((mac) => mac.name).join(", ");
      const delays = afterLimit.map((mac) => shutdownOf(plan, mac.id).delay_minutes);
      const delay = delays.every((value) => value === delays[0]) ? delays[0] : null;
      const when = delay === null ? "once each one's wait after crossing it is up" : delay > 0 ? `${formatDuration(delay * 60_000)} after crossing it` : CHECK_IN;
      const verb = plan.scope === "each" && afterLimit.length === 1 ? "shuts" : "shut";
      warnings.push(`Today's total, ${formatDuration(detail.credited_ms)}, is already past ${formatDuration(limitMs)}. ${names} ${verb} down ${when}, each with a 60-second warning.`);
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
    const body = { plan: result.plan, overtime: result.overtime };
    if (result.limitMs !== null) body.limit_ms = result.limitMs;
    const answer = await api("/v1/day-plan", { method: "PUT", body });
    app.settings.day_plan = answer.day_plan;
    app.settings.day_plan_updated_at_ms = answer.day_plan_updated_at_ms;
    app.settings.limit_ms = answer.limit_ms;
    app.settings.overtime = answer.overtime;
    saved = { plan: normalize(answer.day_plan), limitMs: answer.limit_ms, overtime: answer.overtime };
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
  const next = { plan: normalize(currentPlan()), limitMs: app.settings.limit_ms, overtime: app.settings.overtime ?? DEFAULT_OVERTIME };
  if (saved === null || !edited()) {
    saved = next;
    fill();
  } else if (keyOf(next.plan, next.limitMs, next.overtime) !== keyOf(saved.plan, saved.limitMs, saved.overtime)) {
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
  $("date-add").addEventListener("click", addDate);
  $("plan-discard").addEventListener("click", () => {
    fill();
    $("plan-status").textContent = "";
    showParts();
  });
}
