// Navigation, the one sync timer, login and logout, and boot.
import { $, AuthError, SYNC_MS, TABS, api, app, currentTab, handleFailure, macBridge, onSignOut, readToken, showError, showLogin, tellMac, writeToken } from "./core.js";
import { breaksEdited, checkBreaks, initBreaks, loadBreaks } from "./breaks.js";
import { loadDay, loadToday } from "./day.js";
import { initDevices, loadDevices } from "./devices.js";
import { loadHistory } from "./history.js";
import { initPlan, renderPlan } from "./plan.js";
import { initSettings, renderAccount } from "./settings.js";
import { hideTip } from "./tip.js";

let syncTimer = null;

/** Fetches what the open tab shows. `entering` is the first look at Settings, which loads breaks whole. */
async function refresh({ entering = false } = {}) {
  if (!app.settings) return;
  try {
    const tab = currentTab();
    if (tab === "history") await loadHistory();
    else if (tab === "day") await loadDay();
    else if (tab === "settings") {
      await Promise.all([loadDevices(), entering && !breaksEdited() ? loadBreaks() : checkBreaks()]);
      renderPlan();
    }
    else await loadToday();
    showError("");
  } catch (error) {
    handleFailure(error);
  }
}

function showTab() {
  const tab = currentTab();
  for (const name of TABS) $(`tab-${name}`).hidden = name !== tab;
  // A single day lives under History.
  const highlighted = tab === "day" ? "history" : tab;
  for (const link of document.querySelectorAll(".tabs a")) {
    if (link.dataset.tab === highlighted) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  hideTip();
  refresh({ entering: true });
}

/** Every tab follows the same cadence: whatever is open is fetched again each SYNC_MS while visible. */
function startSync() {
  stopSync();
  syncTimer = setInterval(() => {
    if (document.visibilityState === "visible") refresh();
  }, SYNC_MS);
}

function stopSync() {
  if (syncTimer) clearInterval(syncTimer);
  syncTimer = null;
}

onSignOut(stopSync);

async function enterApp() {
  app.settings = await api("/v1/settings");
  renderAccount();
  $("login-view").hidden = true;
  $("app-view").hidden = false;
  showTab();
  startSync();
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
  if (macBridge) return tellMac("logOut");
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

initSettings();
initPlan();
initBreaks();
initDevices();
$("login-form").addEventListener("submit", login);
$("logout").addEventListener("click", logout);
$("refresh").addEventListener("click", () => refresh());
window.addEventListener("hashchange", () => app.settings && showTab());
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refresh();
});

if (readToken()) {
  enterApp().catch((error) => {
    if (error instanceof AuthError) {
      writeToken(null);
      if (macBridge) return tellMac("logOut");
      showLogin();
    } else {
      showLogin("Could not reach Workholic. Check your connection.");
    }
  });
} else {
  showLogin();
}
