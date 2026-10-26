// One tooltip for the whole page. A node registers a builder; the tooltip follows the pointer.
import { $, el, swatch } from "./core.js";

const tips = new WeakMap();

export function setTip(node, build) {
  tips.set(node, build);
}

export function hideTip() {
  $("tip").hidden = true;
}

export function tipLine(color, text) {
  const row = el("div", "tip-row");
  if (color) row.append(swatch(color));
  row.append(document.createTextNode(text));
  return row;
}

function placeTip(event) {
  const tip = $("tip");
  let node = event.target instanceof Element ? event.target : null;
  while (node && !tips.has(node)) node = node.parentElement;
  if (!node) {
    tip.hidden = true;
    return;
  }
  tip.replaceChildren(...tips.get(node)());
  tip.hidden = false;
  const pad = 12;
  const { width, height } = tip.getBoundingClientRect();
  let x = event.clientX + pad;
  let y = event.clientY - height - pad;
  if (x + width > window.innerWidth - 8) x = event.clientX - width - pad;
  if (y < 8) y = event.clientY + pad;
  tip.style.left = `${Math.max(8, x)}px`;
  tip.style.top = `${y}px`;
}

/** An ⓘ popover opens just under its button, kept on screen. */
function placeInfo(event) {
  const pop = event.target;
  if (event.newState !== "open" || !pop.classList?.contains("info-pop")) return;
  const button = document.querySelector(`[popovertarget="${pop.id}"]`);
  if (!button) return;
  const anchor = button.getBoundingClientRect();
  const { width, height } = pop.getBoundingClientRect();
  const x = Math.min(Math.max(8, anchor.left - 12), window.innerWidth - width - 8);
  const below = anchor.bottom + 6;
  pop.style.left = `${x}px`;
  pop.style.top = `${below + height > window.innerHeight - 8 ? anchor.top - height - 6 : below}px`;
}

// "toggle" does not bubble, so it is caught on the way down.
document.addEventListener("toggle", placeInfo, true);
document.addEventListener("pointermove", placeTip);
document.addEventListener("pointerdown", placeTip);
document.addEventListener("scroll", hideTip, { passive: true });
