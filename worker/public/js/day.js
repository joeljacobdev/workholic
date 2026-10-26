// One day in depth (Today, and a day picked from History), and the device focus they share.
import {
  $, ALL_COLOR, HOUR_MS, api, app, ago, appName, clock, currentTab, dayFromHash, dayKeyIn, deviceBook, el,
  formatDuration, hourLabel, longDayLabel, onSignOut, shiftDay, swatch,
} from "./core.js";
import { blocksOn, currentPlan, plannedMs } from "./plan.js";
import { hideTip, setTip, tipLine } from "./tip.js";

// Credited runs closer than this read as one stretch on the timeline.
const RUN_GAP_MS = 60_000;

// Stacks keep enrollment order so the same device sits in the same place on every bar.
export function byEnrollment(device) {
  return (a, b) => device(a.deviceId).order - device(b.deviceId).order;
}

export function stackBar(parts, total) {
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

export const picked = { focus: null };
let lastDay = null;
const focusListeners = [];

/** History redraws itself through this when the pick changes. */
export function onFocusChange(listener) {
  focusListeners.push(listener);
}

function setFocus(id) {
  picked.focus = picked.focus === id ? null : id;
  hideTip();
  if (currentTab() !== "history" && lastDay) renderDay(lastDay.container, lastDay.detail, { force: true });
  for (const listener of focusListeners) listener();
}

onSignOut(() => {
  picked.focus = null;
  lastDay = null;
});

export function focusBar(ids, device) {
  const bar = el("div", "focus");
  bar.setAttribute("role", "group");
  bar.setAttribute("aria-label", "Show time for");
  const all = el("button", "chip", "All devices");
  all.type = "button";
  all.setAttribute("aria-pressed", String(picked.focus === null));
  all.addEventListener("click", () => setFocus(null));
  bar.append(all);
  for (const id of ids) {
    const info = device(id);
    const chip = el("button", "chip");
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(picked.focus === id));
    chip.append(swatch(info.color), el("span", "", info.display_name));
    chip.addEventListener("click", () => setFocus(id));
    bar.append(chip);
  }
  return bar;
}

/** Tooltip lines splitting a total across devices; only useful when showing all of them. */
export function deviceLines(perDevice, device) {
  return [...perDevice.entries()]
    .map(([deviceId, ms]) => ({ deviceId, ms }))
    .sort(byEnrollment(device))
    .map((part) => tipLine(device(part.deviceId).color, `${device(part.deviceId).display_name} ${formatDuration(part.ms)}`));
}

// ---- One day, in depth ----

/** What the timeline and app list show: every device together, or the focused one. */
function dayView(detail, device) {
  if (picked.focus === null) {
    return { all: true, color: ALL_COLOR, label: "All devices", creditedMs: detail.credited_ms, segments: detail.segments, apps: detail.apps };
  }
  const entry = detail.devices.find((item) => item.deviceId === picked.focus);
  return {
    all: false,
    color: device(picked.focus).color,
    label: device(picked.focus).display_name,
    creditedMs: entry?.creditedMs ?? 0,
    segments: detail.segments.filter((segment) => segment.device_id === picked.focus),
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

/** "synced 3 min ago", kept current between redraws by `ageTexts`. */
function syncedAgo(ms) {
  const node = el("span", "ago", ago(ms));
  node.dataset.at = ms == null ? "" : String(ms);
  return node;
}

function ageTexts(container) {
  for (const node of container.querySelectorAll(".ago")) node.textContent = ago(node.dataset.at === "" ? null : Number(node.dataset.at));
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
  if (shown.length > 1) head.append(el("p", "", "Click one to see only its time"));
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
  list.classList.toggle("focused", picked.focus !== null);
  for (const entry of shown) {
    const info = device(entry.deviceId);
    const item = el("li");
    const row = el("button", "device-row");
    row.type = "button";
    row.setAttribute("aria-pressed", String(picked.focus === entry.deviceId));
    row.addEventListener("click", () => setFocus(entry.deviceId));
    const overlap = entry.rawMs - entry.creditedMs;
    const meta = [];
    if (overlap >= 60_000) meta.push(`${formatDuration(overlap)} overlapped another device`);
    const top = entry.apps?.[0];
    if (top) meta.push(`mostly ${appName(top.appKey)}`);
    const metaNode = el("span", "meta", meta.length ? `${meta.join(", ")}, ` : "");
    metaNode.append(syncedAgo(info.last_upload_at_ms));
    row.append(swatch(info.color), el("span", "name", info.display_name), el("span", "value", formatDuration(entry.creditedMs)));
    row.append(metaNode, el("span", "share", `${Math.round((entry.creditedMs / total) * 100)}%`));
    item.append(row);
    list.append(item);
  }
  panel.append(list);
  return panel;
}

/** Where the "now" line sits on a day's lane, or null when now is not on that day. */
function nowOffset(detail, nowMs) {
  if (nowMs <= detail.start_ms || nowMs >= detail.end_ms) return null;
  return `${((nowMs - detail.start_ms) / (detail.end_ms - detail.start_ms)) * 100}%`;
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
  head.append(el("p", "", `First ${clock(first)}, last ${clock(last)}`));

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
  const offset = nowOffset(detail, nowMs);
  if (offset !== null) {
    const now = el("b", "now");
    now.style.left = offset;
    now.title = "Now";
    lane.append(now);
  }

  // Minutes per hour, stacked by device when showing them all.
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
    const parts = view.all
      ? [...perDevice.entries()].map(([deviceId, ms]) => ({ deviceId, ms })).sort(byEnrollment(device)).map((part) => [device(part.deviceId).color, part.ms])
      : [[view.color, sum]];
    for (const [color, ms] of parts) {
      if (ms <= 0) continue;
      const fill = el("span");
      fill.style.setProperty("--c", color);
      fill.style.height = `${(ms / HOUR_MS) * 100}%`;
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
  panel.append(grid, lane, axis(detail, 6));

  // Which color is which device, when the columns are split by device.
  const shown = view.all ? [...new Set(view.segments.map((segment) => segment.device_id))] : [];
  if (shown.length > 1) {
    const legend = el("div", "legend");
    for (const id of shown.sort((a, b) => device(a).order - device(b).order)) {
      const item = el("span");
      item.append(swatch(device(id).color), document.createTextNode(device(id).display_name));
      legend.append(item);
    }
    panel.append(legend);
  }
  if (busiest.ms > 0) {
    head.querySelector("p").textContent += `. Busiest ${clock(busiest.hour)}, ${formatDuration(busiest.ms)}`;
  }
  return panel;
}

function appsPanel(detail, view, device) {
  const panel = el("div", "panel");
  const head = el("div", "panel-head");
  head.append(el("h2", "", "Most used"));
  panel.append(head);
  const apps = view.apps.slice(0, 10);
  if (apps.length === 0) {
    const message = view.all ? "No app time on this day." : `${view.label} has no app time on this day.`;
    panel.append(el("p", "muted empty", message));
    return panel;
  }
  if (view.apps.length > apps.length) head.append(el("p", "", `Top ${apps.length} of ${view.apps.length}`));
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
    const name = el("span", "name", appName(app.appKey));
    name.title = app.appKey;
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
    const track = el("div");
    track.append(bar);
    item.append(name, track, el("span", "value", formatDuration(app.creditedMs)));
    list.append(item);
  }
  panel.append(list);
  return panel;
}

/** What each container last drew, so a refresh with nothing new leaves the page as it is. */
const drawn = new WeakMap();

function renderDay(container, detail, { force = false } = {}) {
  lastDay = { container, detail };
  // Only what is drawn: a Mac checking in changes when it was last seen, which this page does not show.
  const key = JSON.stringify([
    picked.focus, detail.day, detail.credited_ms, detail.ceiling_ms, detail.devices, detail.apps, detail.segments,
    detail.device_info.map((info) => [info.device_id, info.display_name, info.last_upload_at_ms]),
  ]);
  if (!force && drawn.get(container) === key) {
    // Only the clock has moved; tooltips, focus and scroll stay put.
    const now = container.querySelector(".lane .now");
    const offset = nowOffset(detail, Date.now());
    if (now && offset !== null) now.style.left = offset;
    ageTexts(container);
    return;
  }
  drawn.set(container, key);
  const device = deviceBook(detail.device_info);
  const present = detail.devices.filter((entry) => entry.rawMs > 0).sort(byEnrollment(device)).map((entry) => entry.deviceId);
  if (picked.focus !== null && !present.includes(picked.focus)) present.push(picked.focus);
  const shown = dayView(detail, device);
  const nodes = [];
  if (present.length > 1 || picked.focus !== null) nodes.push(focusBar(present, device));
  nodes.push(timelinePanel(detail, shown, device, Date.now()), appsPanel(detail, shown, device), devicesPanel(detail, device));
  container.replaceChildren(...nodes);
}

// ---- Today ----

export async function loadToday() {
  const today = dayKeyIn(app.settings.timezone);
  const detail = await api(`/v1/days/${today}`);
  const used = detail.credited_ms;
  // With time blocks, today is measured against what its blocks add up to, not the daily limit.
  const plan = currentPlan();
  const planner = plan.mode === "planner";
  const limit = planner ? plannedMs(blocksOn(plan, today)) : detail.ceiling_ms;
  const over = limit !== null && used > limit;

  $("today-used").textContent = formatDuration(used);
  $("today-of").textContent = limit === null ? "Today, no daily limit" : planner ? `Today, of ${formatDuration(limit)} planned` : `Today, of ${formatDuration(limit)}`;
  const fraction = limit ? Math.min(used / limit, 1) : 0;
  const meter = $("gauge-arc");
  meter.style.width = `${fraction * 100}%`;
  meter.classList.toggle("over", over);

  $("today-date").textContent = over ? (planner ? "Past the plan" : "Over the limit") : "Left today";
  $("today-left").textContent = limit === null ? "No limit" : over ? formatDuration(used - limit) : formatDuration(limit - used);
  $("today-left").style.color = over ? "var(--over)" : "";
  $("today-limit-label").textContent = planner ? "Planned today" : "Daily limit";
  $("today-limit").textContent = limit === null ? "Not set" : formatDuration(limit);
  $("today-devices").textContent = String(detail.devices.filter((entry) => entry.rawMs > 0).length);
  $("tab-today").classList.remove("loading");
  renderDay($("today-detail"), detail);
  $("updated-at").textContent = new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

// ---- Day view ----

export async function loadDay() {
  const key = dayFromHash();
  const today = dayKeyIn(app.settings.timezone);
  const detail = await api(`/v1/days/${key}`);
  // Stepping to another day has to draw it, even if it looks just like the last.
  if (dayFromHash() !== key) return;
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
