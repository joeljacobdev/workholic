// Breaks: the every-few-minutes pauses, the past-the-limit pause, and the set-time pauses.
import { $, AuthError, api, app, el, handleFailure, onSignOut, tellMac } from "./core.js";

const BREAK_ERRORS = {
  bad_every_minutes: "Remind every 1 to 240 minutes.",
  bad_items: "Keep between 1 and 20 pauses.",
  bad_item_message: "Every pause needs a short message (up to 200 characters).",
  bad_item_minutes: "Each pause lasts 1 to 180 minutes.",
  bad_overtime: "The past-the-limit pause needs a message, 1 to 180 minutes, and a gap of 1 to 240 minutes.",
  bad_scheduled: "Each set time needs a time, a message, and 1 to 180 minutes (up to 10 times).",
};
let breaksDirty = false;
/** The account's `updated_at_ms` for the breaks shown in the form. */
let breaksAt = null;

onSignOut(() => {
  breaksDirty = false;
});

export function breaksEdited() {
  return breaksDirty;
}

function breakRow(item) {
  const row = el("li");
  row.dataset.id = item.id;
  const message = el("input", "msg text-field");
  message.value = item.message;
  message.placeholder = "What this pause is for";
  message.maxLength = 200;
  message.setAttribute("aria-label", "Pause message");
  const opts = el("div", "opts");
  const minutesLabel = el("label");
  const minutes = el("input", "minutes num-field");
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
  const remove = el("button", "minus remove", "−");
  remove.type = "button";
  remove.setAttribute("aria-label", "Remove pause");
  remove.addEventListener("click", () => {
    row.remove();
    breaksDirty = true;
    syncRemoveButtons();
  });
  row.append(remove, message, opts);
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
  const message = el("input", "msg text-field");
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
  const minutes = el("input", "minutes num-field");
  minutes.type = "number";
  minutes.min = "1";
  minutes.max = "180";
  minutes.inputMode = "numeric";
  minutes.value = String(entry.minutes);
  minutesLabel.append(minutes, document.createTextNode("min"));
  when.append(atLabel, minutesLabel);
  const remove = el("button", "minus remove", "−");
  remove.type = "button";
  remove.setAttribute("aria-label", "Remove set time");
  remove.addEventListener("click", () => {
    row.remove();
    breaksDirty = true;
    syncScheduledAdd();
  });
  row.append(remove, message, when);
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
  if (settings.overtime) {
    renderRule("overtime", settings.overtime);
    $("overtime-every").value = String(settings.overtime.every_minutes);
  }
  $("scheduled-items").replaceChildren(...(settings.scheduled ?? []).map(scheduledRow));
  syncScheduledAdd();
  breaksDirty = false;
  breaksAt = settings.updated_at_ms ?? 0;
}

// On each sync while Settings is open, a change made on a Mac or another browser shows up.
// Unsaved edits here are left alone: the latest save wins, so saving them replaces the other change.
// The same answer keeps the account's limit current for the shutdown previews.
export async function checkBreaks() {
  try {
    const latest = await api("/v1/settings");
    // Signed out while it was asked: stay signed out.
    if (!app.settings) return;
    app.settings = latest;
    if (latest.breaks_updated_at_ms == null || latest.breaks_updated_at_ms === breaksAt) return;
    if (breaksDirty) {
      $("breaks-status").textContent = "Breaks changed on another device. Saving replaces that change with yours.";
    } else {
      await loadBreaks();
    }
  } catch (error) {
    if (error instanceof AuthError) handleFailure(error);
  }
}

export async function loadBreaks() {
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
    overtime: { ...readRule("overtime"), every_minutes: Number($("overtime-every").value) },
    scheduled,
  };
  $("breaks-save").disabled = true;
  try {
    renderBreaks(await api("/v1/breaks", { method: "PUT", body }));
    $("breaks-status").textContent = body.enabled ? "Breaks saved. Breaks are on." : "Breaks saved. Breaks are off.";
    tellMac("saved");
  } catch (error) {
    if (error instanceof AuthError) return handleFailure(error);
    $("breaks-status").textContent = BREAK_ERRORS[error.message] ?? `Could not save (${error.message}).`;
  } finally {
    $("breaks-save").disabled = false;
  }
}

export function initBreaks() {
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
}
