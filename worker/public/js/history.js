// The last 14 days, one bar each.
import { $, ALL_COLOR, HOUR_MS, api, app, currentTab, dayKeyIn, dayLabel, deviceBook, el, formatDuration, longDayLabel, onSignOut, shiftDay } from "./core.js";
import { deviceLines, focusBar, onFocusChange, picked, stackBar } from "./day.js";
import { setTip } from "./tip.js";

let lastStats = null;
/** What was last drawn, so a refresh with nothing new leaves the list as it is. */
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

function renderHistory(stats, { force = false } = {}) {
  lastStats = stats;
  const today = dayKeyIn(app.settings.timezone);
  // Only what is drawn: a Mac checking in changes when it was last seen, which this list does not show.
  const key = JSON.stringify([picked.focus, today, stats.days, (stats.device_info ?? []).map((info) => [info.device_id, info.display_name])]);
  if (!force && key === drawnKey) return;
  drawnKey = key;
  const focus = picked.focus;
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

  const items = [];
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
    items.push(item);
  }
  $("history-list").replaceChildren(...items);
}
