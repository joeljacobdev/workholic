// The page's one modal dialog, in place of the browser's confirm(). Cancel has the focus and Esc
// cancels, so a stray key never confirms. Nothing happens until the confirm button is pressed.
import { $, el, onSignOut } from "./core.js";

onSignOut(() => closeDialog());

/**
 * Shows the dialog and resolves true once `onConfirm` succeeds, or false when cancelled.
 * `onConfirm` returns true to close, or a message to show while the dialog stays open.
 */
export function openDialog({ title, body, confirmLabel, danger = false, onConfirm = async () => true }) {
  const dialog = $("dialog");
  const ok = $("dialog-ok");
  const cancel = $("dialog-cancel");
  const status = $("dialog-status");
  $("dialog-title").textContent = title;
  $("dialog-body").replaceChildren(...[body].flat().map((part) => (typeof part === "string" ? el("p", "", part) : part)));
  status.textContent = "";
  ok.textContent = confirmLabel;
  ok.className = danger ? "btn destructive-fill" : "btn default";
  ok.disabled = false;

  return new Promise((resolve) => {
    const listening = new AbortController();
    let busy = false;
    const done = (value) => {
      listening.abort();
      if (dialog.open) dialog.close();
      resolve(value);
    };
    ok.addEventListener("click", async () => {
      busy = ok.disabled = cancel.disabled = true;
      status.textContent = "";
      try {
        const outcome = await onConfirm();
        if (outcome === true) return done(true);
        status.textContent = outcome;
      } catch (error) {
        status.textContent = `Something went wrong (${error.message}).`;
      } finally {
        busy = ok.disabled = cancel.disabled = false;
      }
    }, { signal: listening.signal });
    cancel.addEventListener("click", () => done(false), { signal: listening.signal });
    // A request under way is not walked away from: what it did is shown when it answers.
    dialog.addEventListener("cancel", (event) => busy && event.preventDefault(), { signal: listening.signal });
    // Esc, or the page signing out underneath it.
    dialog.addEventListener("close", () => done(false), { signal: listening.signal });
    dialog.showModal();
    cancel.focus();
  });
}

export function closeDialog() {
  if ($("dialog").open) $("dialog").close();
}
