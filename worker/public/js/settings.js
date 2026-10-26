// The account facts and, inside the Mac app, the "This Mac" panel.
import { $, app, formatDuration, macBridge, tellMac } from "./core.js";
import { renderPlan } from "./plan.js";

export function renderAccount() {
  $("set-username").textContent = app.settings.username;
  $("set-timezone").textContent = app.settings.timezone;
  $("set-idle").textContent = formatDuration(app.settings.idle_threshold_ms);
  renderPlan();
}

// ---- Inside the Mac app ----
// There the "This Mac" panel holds the settings that live on that Mac, and logging out logs the Mac out.

function renderMac(state) {
  if (!macBridge || !state) return;
  $("mac-panel").hidden = false;
  $("mac-login").checked = Boolean(state.openAtLogin);
  $("mac-login-note").hidden = !state.openAtLoginNeedsApproval;
  $("mac-lock").checked = Boolean(state.pauseLocks);
  $("mac-version").textContent = state.version ?? "";
  $("mac-version-row").hidden = !state.version;
}

export function initSettings() {
  if (!macBridge) return;
  window.workholicMac = { update: renderMac };
  $("logout").textContent = "Log Out of This Mac";
  $("mac-login").addEventListener("change", (event) => tellMac("openAtLogin", event.target.checked));
  $("mac-lock").addEventListener("change", (event) => tellMac("pauseLocks", event.target.checked));
  renderMac(window.workholicMacState);
}
