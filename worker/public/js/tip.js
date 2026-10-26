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

document.addEventListener("pointermove", placeTip);
document.addEventListener("pointerdown", placeTip);
document.addEventListener("scroll", hideTip, { passive: true });
