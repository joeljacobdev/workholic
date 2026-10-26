// The last 14 days: a bar for each, then the days as a list. Each opens the day.
import { $, ALL_COLOR, HOUR_MS, api, app, currentTab, dayKeyIn, dayLabel, deviceBook, el, formatDuration, longDayLabel, onSignOut, shiftDay } from "./core.js";
import { deviceLines, focusBar, onFocusChange, picked } from "./day.js";
import { setTip } from "./tip.js";

let lastStats = null;
/** What was last drawn, so a refresh with nothing new leaves the page as it is. */
let drawnKey = null;

onFocusChange(() => {
  if (currentTab() === "history" && lastStats) renderHistory(lastStats, { force: true });
});

onSignOut(() => {
  lastStats = null;
  drawnKey = null;
});

export async function loadHistory() {
  const today = dayKeyIn(app.settings.timezone);
  const from = shiftDay(today, -13);
  renderHistory(await api(`/v1/stats?from=${from}&to=${today}`));
}

/** "Mon" for the chart's labels; the list spells days out. */
function weekday(key) {
  return new Date(`${key}T12:00:00Z`).toLocaleDateString([], { weekday: "narrow", timeZone: "UTC" });
}

function chartLine(kind, ms, scale, label) {
  const line = el("div", `line ${kind}`);
  line.style.bottom = `${(ms / scale) * 100}%`;
  line.append(el("em", "", label));
  return line;
}

function renderHistory(stats, { force = false } = {}) {
  lastStats = stats;
  const today = dayKeyIn(app.settings.timezone);
  // Only what is drawn: a Mac checking in changes when it was last seen, which this page does not show.
  const key = JSON.stringify([picked.focus, today, stats.days, (stats.device_info ?? []).map((info) => [info.device_id, info.display_name])]);
  if (!force && key === drawnKey) return;
  drawnKey = key;
  const focus = picked.focus;
  const device = deviceBook(stats.device_info ?? []);
  const days = stats.days;
  const usedOn = (day) => (focus === null ? day.credited_ms : (day.devices.find((entry) => entry.deviceId === focus)?.creditedMs ?? 0));
  const color = focus === null ? ALL_COLOR : device(focus).color;
  // The limit covers all devices together, so it only marks the overall view.
  const limit = focus === null ? days[days.length - 1]?.ceiling_ms ?? null : null;
  const scale = Math.max(HOUR_MS, limit ?? 0, ...days.map(usedOn)) * 1.08;

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

  // The chart, oldest on the left like Screen Time.
  const chart = el("div", "days");
  chart.setAttribute("role", "img");
  chart.setAttribute("aria-label", `Daily time for the last ${days.length} days. ${summary}.`);
  for (const day of days) {
    const used = usedOn(day);
    const over = focus === null && day.over;
    const column = el("a", day.day === today ? "today" : "");
    if (used === 0) column.classList.add("zero");
    column.href = `#day/${day.day}`;
    column.setAttribute("aria-label", `${longDayLabel(day.day)}: ${formatDuration(used)}`);
    const fill = el("span");
    fill.style.setProperty("--c", over ? "var(--over)" : color);
    fill.style.height = `${(used / scale) * 100}%`;
    column.append(fill);
    const split = new Map(day.devices.filter((entry) => entry.creditedMs > 0).map((entry) => [entry.deviceId, entry.creditedMs]));
    setTip(column, () => [
      el("strong", "", `${longDayLabel(day.day)}, ${used === 0 ? "no time" : formatDuration(used)}`),
      ...(focus === null && split.size > 1 ? deviceLines(split, device) : []),
    ]);
    chart.append(column);
  }
  if (limit !== null) chart.append(chartLine("limit", limit, scale, `Limit ${formatDuration(limit)}`));
  if (average > 0) chart.append(chartLine("avg", average, scale, `Avg ${formatDuration(average)}`));
  const labels = el("div", "day-labels");
  for (const day of days) labels.append(el("span", day.day === today ? "today" : "", weekday(day.day)));
  $("history-chart").replaceChildren(chart, labels);

  // The list, newest first.
  const items = [];
  for (const day of [...days].reverse()) {
    const used = usedOn(day);
    const over = focus === null && day.over;
    const item = el("li");
    const link = el("a");
    link.href = `#day/${day.day}`;
    link.setAttribute("aria-label", `${longDayLabel(day.day)}: ${formatDuration(used)}${over ? ", over the limit" : ""}`);
    const label = el("span", day.day === today ? "day today" : "day", dayLabel(day.day, today));
    const value = el("span", over ? "value over" : used === 0 ? "value none" : "value", used === 0 ? "None" : formatDuration(used));
    link.append(label, value, el("span", "chev", "›"));
    item.append(link);
    items.push(item);
  }
  $("history-list").replaceChildren(...items);
}
