// The account's devices, and shutting Macs down now: one, or several picked together. Nothing is
// asked of a Mac until the dialog's button is pressed. The daily shutdown is part of the day plan.
import { $, AuthError, api, clock, deviceBook, el, handleFailure, onSignOut, swatch, ago } from "./core.js";
import { openDialog } from "./dialog.js";

const ERRORS = {
  bad_device_ids: "Pick between 1 and 50 Macs.",
  no_such_device: "That device is no longer on the account.",
  revoked: "That Mac is signed out. Log in on it first.",
  not_supported: "Only a Mac can shut down from here.",
};

/** Device rows by id. They are kept across syncs and updated in place. */
const rows = new Map();
/** Macs picked to shut down together. */
const selected = new Set();

onSignOut(() => {
  rows.clear();
  selected.clear();
  $("settings-devices").replaceChildren();
  syncSelection();
});

function failure(error, doing) {
  if (error instanceof AuthError) {
    handleFailure(error);
    return "Your session ended.";
  }
  return ERRORS[error.message] ?? `Could not ${doing} (${error.message}).`;
}

function canShutDown(entry) {
  return !entry.revoked && entry.platform === "macos";
}

/** A running Mac checks in every minute, or every five while someone is at it, and is marked seen at most once a minute. */
function presence(ms) {
  if (ms == null) return { on: false, text: null };
  const minutes = (Date.now() - ms) / 60_000;
  if (minutes < 7) return { on: true, text: "on now" };
  if (minutes < 60) return { on: false, text: `last on ${Math.round(minutes)} min ago` };
  if (minutes < 48 * 60) return { on: false, text: `last on ${Math.round(minutes / 60)} h ago` };
  return { on: false, text: `last on ${Math.round(minutes / 1440)} days ago` };
}

// ---- One device ----

function deviceRow(id) {
  const row = { entry: null, shown: null };
  const item = el("li", "device");
  const pick = el("input", "pick");
  pick.type = "checkbox";
  pick.addEventListener("change", () => {
    if (pick.checked) selected.add(id);
    else selected.delete(id);
    syncSelection();
  });
  const color = swatch("var(--dev-other)");
  const name = el("span", "name");
  const dot = el("span", "dot");
  const head = el("div", "head");
  head.append(color, name, dot);
  const meta = el("span", "meta");
  const actions = el("div", "actions");
  const status = el("p", "row-status");
  status.setAttribute("role", "status");

  const body = el("div", "body");
  body.append(head, meta, actions, status);
  item.append(pick, body);

  function renderActions(entry) {
    const shutdown = entry.shutdown;
    const parts = [];
    if (shutdown?.state === "pending") {
      parts.push(el("span", "", `Shutdown asked at ${clock(shutdown.requested_at_ms)}. It runs when this Mac next checks in.`));
      const cancel = el("button", "btn", "Cancel Shutdown");
      cancel.type = "button";
      cancel.addEventListener("click", () => withdraw(cancel));
      parts.push(cancel);
      actions.replaceChildren(...parts);
      return;
    }
    // The Mac acknowledges before it acts, so this says the order arrived, not that it powered off.
    if (shutdown?.state === "delivered") parts.push(el("span", "", `Shutdown sent to this Mac at ${clock(shutdown.delivered_at_ms)}.`));
    if (shutdown?.state === "failed") parts.push(el("span", "", `Shutdown at ${clock(shutdown.delivered_at_ms)} did not go through (${shutdown.result.slice("failed:".length)}).`));
    const ask = el("button", "btn destructive", "Shut Down…");
    ask.type = "button";
    ask.addEventListener("click", () => askShutdown());
    parts.push(ask);
    actions.replaceChildren(...parts);
  }

  function askShutdown() {
    const entry = row.entry;
    return openDialog({
      title: `Shut down ${entry.display_name}?`,
      body: "It shuts down within a few minutes if it is on, or the next time Workholic runs on it. Unsaved work in open apps can stop the shutdown or be lost.",
      confirmLabel: "Shut Down",
      danger: true,
      onConfirm: async () => {
        try {
          entry.shutdown = await api(`/v1/devices/${id}/shutdown`, { method: "POST" });
          update(entry);
          status.textContent = "";
          return true;
        } catch (error) {
          return failure(error, "ask for the shutdown");
        }
      },
    });
  }

  async function withdraw(button) {
    button.disabled = true;
    button.textContent = "Cancelling…";
    try {
      const answer = await api(`/v1/devices/${id}/shutdown`, { method: "DELETE" });
      row.entry.shutdown = answer.shutdown;
      status.textContent = answer.shutdown?.state === "delivered" ? "Too late to cancel: the Mac already has it." : "";
      update(row.entry);
    } catch (error) {
      status.textContent = failure(error, "cancel the shutdown");
      button.disabled = false;
      button.textContent = "Cancel Shutdown";
    }
  }

  function update(entry, swatchColor) {
    row.entry = entry;
    if (swatchColor) color.style.setProperty("--c", swatchColor);
    name.textContent = entry.display_name;
    const able = canShutDown(entry);
    pick.hidden = !able;
    pick.checked = selected.has(id);
    pick.setAttribute("aria-label", `Select ${entry.display_name}`);
    const seen = presence(entry.last_seen_at_ms);
    dot.hidden = entry.revoked;
    dot.classList.toggle("on", seen.on);
    dot.title = seen.on ? "On now" : "Not on now";
    const facts = [entry.platform === "macos" ? "Mac" : entry.platform];
    if (entry.revoked) facts.push("signed out");
    else facts.push(...[seen.text, ago(entry.last_upload_at_ms)].filter(Boolean));
    meta.textContent = facts.join(", ");

    actions.hidden = !able;
    if (!able) return;
    const shown = JSON.stringify(entry.shutdown);
    if (shown !== row.shown) {
      row.shown = shown;
      renderActions(entry);
    }
  }

  return { item, update, entry: () => row.entry };
}

// ---- Several Macs at once ----

function picks() {
  return [...rows.values()].map((row) => row.entry()).filter((entry) => selected.has(entry.device_id));
}

function syncSelection() {
  for (const id of selected) {
    const entry = rows.get(id)?.entry();
    if (!entry || !canShutDown(entry)) selected.delete(id);
  }
  const able = [...rows.values()].filter((row) => canShutDown(row.entry())).length;
  const count = selected.size;
  $("device-bulk").hidden = count === 0;
  $("bulk-count").textContent = count === 1 ? "1 Mac selected" : `${count} Macs selected`;
  $("devices-all-label").hidden = able < 2;
  $("devices-all").checked = able > 0 && count === able;
  $("devices-all").indeterminate = count > 0 && count < able;
}

function nameList(entries) {
  const list = el("ul", "dialog-list");
  for (const entry of entries) {
    const item = el("li");
    item.append(el("strong", "", entry.display_name));
    list.append(item);
  }
  return list;
}

function shutDownMany() {
  const entries = picks();
  if (entries.length === 0) return;
  const count = entries.length;
  openDialog({
    title: count === 1 ? `Shut down ${entries[0].display_name}?` : `Shut down ${count} Macs?`,
    body: [
      nameList(entries),
      "Each shuts down within a few minutes if it is on, or the next time Workholic runs on it. Unsaved work in open apps can stop the shutdown or be lost.",
    ],
    confirmLabel: count === 1 ? "Shut Down" : `Shut Down ${count} Macs`,
    danger: true,
    onConfirm: async () => {
      try {
        const answer = await api("/v1/shutdowns", { method: "POST", body: { device_ids: entries.map((entry) => entry.device_id) } });
        for (const { device_id, shutdown } of answer.shutdowns) {
          const entry = rows.get(device_id)?.entry();
          if (!entry) continue;
          entry.shutdown = shutdown;
          rows.get(device_id).update(entry);
        }
        $("bulk-status").textContent = `Shutdown asked of ${count === 1 ? entries[0].display_name : `${count} Macs`}. Each runs it when it next checks in.`;
        return true;
      } catch (error) {
        return failure(error, "ask for the shutdowns");
      }
    },
  });
}

export async function loadDevices() {
  const stats = await api("/v1/stats");
  const info = stats.device_info ?? [];
  const device = deviceBook(info);
  const list = $("settings-devices");
  const present = new Set();
  info.forEach((entry, index) => {
    present.add(entry.device_id);
    let row = rows.get(entry.device_id);
    if (!row) {
      row = deviceRow(entry.device_id);
      rows.set(entry.device_id, row);
    }
    row.update(entry, device(entry.device_id).color);
    if (list.children[index] !== row.item) list.insertBefore(row.item, list.children[index] ?? null);
  });
  for (const [id, row] of rows) {
    if (present.has(id)) continue;
    row.item.remove();
    rows.delete(id);
  }
  $("settings-devices-empty").hidden = info.length > 0;
  syncSelection();
}

export function initDevices() {
  $("devices-all").addEventListener("change", (event) => {
    selected.clear();
    if (event.target.checked) {
      for (const [id, row] of rows) if (canShutDown(row.entry())) selected.add(id);
    }
    for (const row of rows.values()) row.update(row.entry());
    syncSelection();
  });
  $("bulk-shutdown").addEventListener("click", shutDownMany);
  $("bulk-clear").addEventListener("click", () => {
    selected.clear();
    for (const row of rows.values()) row.update(row.entry());
    syncSelection();
    $("bulk-status").textContent = "";
  });
}
