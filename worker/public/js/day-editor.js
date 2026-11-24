// The day editor: one date's time blocks on a calendar column, in a sidebar. Blocks are made, moved,
// resized and deleted on the column, or set exactly in the row under it. Nothing is stored here: each
// change goes into the page's plan (plan.js), and the page's Save stores it.
//
// Mouse: drag on free time to make a block, click free time for a two-hour block, drag a block to move
// it, drag its top or bottom edge to resize it, click it to select it.
// Touch: a swipe always scrolls. Tap free time for a two-hour block, tap a block to select it; a
// selected block moves and resizes by its handles. Hold free time, then drag, to make a block.
import { $, el, formatDuration, minuteOfDay, onSignOut, shiftDay } from "./core.js";
import { MAX_BLOCKS, DAY_MINUTES, blockText, create, endText, hhmm, minutes, move, place, plannedMs, resize, setExact } from "./block-edit.js";

const HOUR_PX = 48;
/** How far a press moves before it is a drag (mouse) or a swipe (touch). */
const DRAG_PX = 4;
const SWIPE_PX = 8;
const HOLD_MS = 400;
/** A drag this close to the top or bottom of the column scrolls it. */
const SCROLL_EDGE_PX = 40;
/** Where the column opens on a day without blocks. */
const OPEN_AT = 8 * 60;
/** "Add block": an hour after the last block, otherwise 09:00 (as the old block rows did). */
const FIRST_START = 9 * 60;
/** At this width the editor sits beside the settings; below it, over them. */
const WIDE = matchMedia("(min-width: 1100px)");

/** What plan.js gives the editor: the edited blocks of a date, and how to change them. */
let host = null;
let day = null;
/** The index of the selected block, or null. */
let selected = null;
/** The press under way: a click, a tap, a drag, or a swipe. */
let press = null;
/** One element per block, reused so a drag never loses the element under the finger. */
const shown = [];

onSignOut(() => closeDayEditor());

const blocks = () => host.blocksOn(day);

/** "3 hours", "1 hour 30 minutes", for screen readers. */
function lengthWords(total) {
  const hours = Math.floor(total / 60);
  const mins = total % 60;
  const part = (n, word) => (n ? `${n} ${word}${n === 1 ? "" : "s"}` : "");
  return [part(hours, "hour"), part(mins, "minute")].filter(Boolean).join(" ") || "0 minutes";
}

/** The minute under a point on the screen, within the day. */
function minuteAt(clientY) {
  const top = $("day-editor-day").getBoundingClientRect().top;
  return Math.min(Math.max(Math.round(((clientY - top) / HOUR_PX) * 60), 0), DAY_MINUTES);
}

const px = (minute) => `${(minute / 60) * HOUR_PX}px`;

function say(message) {
  $("day-editor-problem").textContent = message;
  $("day-editor-problem").hidden = !message;
}

// ---- Drawing ----

function blockNode() {
  const node = el("button", "day-block");
  node.type = "button";
  const top = el("span", "day-edge top");
  top.dataset.edge = "start";
  const bottom = el("span", "day-edge bottom");
  bottom.dataset.edge = "end";
  const time = el("span", "day-block-time");
  const length = el("span", "day-block-length");
  node.append(top, time, length, bottom);
  return { node, time, length };
}

function render() {
  if (!host || !$("day-editor").open) return;
  const list = blocks();
  if (selected !== null && selected >= list.length) selected = null;
  const label = host.dateText(day);
  $("day-editor-date").value = day;
  $("day-editor-day").setAttribute("aria-label", `Blocks on ${label}`);
  $("day-editor-summary").textContent = list.length
    ? `${formatDuration(plannedMs(list))} planned`
    : "No blocks. This day follows the daily limit.";

  const layer = $("day-editor-blocks");
  while (shown.length < list.length) {
    const part = blockNode();
    shown.push(part);
    layer.append(part.node);
  }
  while (shown.length > list.length) shown.pop().node.remove();
  list.forEach(([start, end], index) => {
    const { node, time, length } = shown[index];
    node.dataset.index = String(index);
    node.style.top = px(start);
    node.style.height = px(end - start);
    time.textContent = blockText([start, end]);
    length.textContent = formatDuration((end - start) * 60_000);
    // The length shows when the block has room for a second line.
    length.hidden = end - start < 45;
    node.classList.toggle("short", end - start < 30);
    node.classList.toggle("selected", index === selected);
    node.setAttribute("aria-label", `${hhmm(start)} to ${endText(end)}, ${lengthWords(end - start)}`);
    node.setAttribute("aria-pressed", String(index === selected));
  });

  // The current time, on today only.
  const now = $("day-editor-now");
  now.hidden = day !== host.todayKey();
  if (!now.hidden) now.style.top = px(minuteOfDay());

  // The drag's times, beside the block being dragged.
  const tag = $("day-editor-drag");
  const dragged = press?.kind && press.kind !== "swipe" && selected !== null ? list[selected] : null;
  tag.hidden = !dragged;
  if (dragged) {
    tag.textContent = blockText(dragged);
    tag.style.top = px(dragged[0]);
  }

  const edit = $("day-editor-edit");
  edit.hidden = selected === null;
  if (selected !== null) {
    // A field being typed in keeps what is typed, unless another block is now selected.
    const [start, end] = list[selected];
    const which = `${day} ${selected}`;
    for (const [id, value] of [["day-editor-start", hhmm(start)], ["day-editor-end", hhmm(end % DAY_MINUTES)]]) {
      if (document.activeElement !== $(id) || $(id).dataset.block !== which) $(id).value = value;
      $(id).dataset.block = which;
    }
  }
  $("day-editor-add").disabled = list.length >= MAX_BLOCKS;
  $("day-editor-remove").hidden = list.length === 0;
}

function scrollToStart() {
  const list = blocks();
  const first = list.length ? list[0][0] : OPEN_AT;
  $("day-editor-scroll").scrollTop = Math.max(0, (first / 60) * HOUR_PX - 24);
}

// ---- Changes ----

/** Puts a result into the plan, or says why not. Returns the new blocks, or null. */
function apply(result) {
  if (!result.ok) {
    say(result.message);
    return null;
  }
  say("");
  host.setBlocks(day, result.blocks);
  return result.blocks;
}

/** The index of the block in `after` that `before` did not have. */
const newIndex = (before, after) => after.findIndex(([start, end]) => !before.some(([s, e]) => s === start && e === end));

function select(index) {
  selected = index;
  say("");
  render();
}

function addBlock() {
  const list = blocks();
  const last = list.length ? list[list.length - 1][1] : null;
  const start = last === null ? FIRST_START : Math.min(last + 60, DAY_MINUTES - 60);
  const next = apply(place(list, start));
  if (!next) return;
  select(newIndex(list, next));
  $("day-editor-start").focus();
}

function deleteSelected() {
  if (selected === null) return;
  const list = blocks();
  const index = selected;
  selected = null;
  say("");
  host.setBlocks(day, list.filter((_, i) => i !== index));
  render();
  $("day-editor-day").focus();
}

/** The exact times typed in the edit row. */
function typed() {
  if (selected === null) return;
  const start = minutes($("day-editor-start").value, false);
  const end = minutes($("day-editor-end").value, true);
  if (start === null || end === null) return say("Enter both times.");
  const next = apply(setExact(blocks(), selected, start, end));
  if (!next) return;
  selected = next.findIndex(([s, e]) => s === start && e === end);
  render();
}

// ---- Pointer ----

function onDown(event) {
  if (press || event.button !== 0) return;
  const target = event.target;
  const node = target.closest(".day-block");
  const touch = event.pointerType === "touch";
  const index = node ? Number(node.dataset.index) : null;
  const list = blocks();
  const minute = minuteAt(event.clientY);
  press = {
    id: event.pointerId, touch, x: event.clientX, y: event.clientY, lastY: event.clientY,
    origin: list, index, edge: node ? target.closest(".day-edge")?.dataset.edge ?? null : null,
    anchor: minute, grab: index === null ? 0 : minute - list[index][0], kind: null, timer: 0, frame: 0,
  };
  // On touch only a selected block drags; any other press may still turn into a scroll.
  if (touch && index === null) press.timer = setTimeout(holdToCreate, HOLD_MS);
  $("day-editor-day").setPointerCapture(event.pointerId);
}

function holdToCreate() {
  if (!press || press.kind !== null) return;
  navigator.vibrate?.(10);
  begin("create");
}

function begin(kind) {
  clearTimeout(press.timer);
  press.kind = kind;
  if (kind === "swipe") return;
  if (press.index !== null) selected = press.index;
  drag();
  const scroll = () => {
    if (!press || press.kind === "swipe") return;
    const box = $("day-editor-scroll").getBoundingClientRect();
    const over = press.lastY < box.top + SCROLL_EDGE_PX ? press.lastY - (box.top + SCROLL_EDGE_PX)
      : press.lastY > box.bottom - SCROLL_EDGE_PX ? press.lastY - (box.bottom - SCROLL_EDGE_PX) : 0;
    if (over) {
      const before = $("day-editor-scroll").scrollTop;
      $("day-editor-scroll").scrollTop += Math.round(over / 3);
      if ($("day-editor-scroll").scrollTop !== before) drag();
    }
    press.frame = requestAnimationFrame(scroll);
  };
  press.frame = requestAnimationFrame(scroll);
}

/** The press's change, worked out from the blocks as they were when it began. */
function drag() {
  const minute = minuteAt(press.lastY);
  const { origin, index } = press;
  const result = press.kind === "move" ? move(origin, index, minute - press.grab)
    : press.kind === "resize" ? resize(origin, index, press.edge, minute)
    : create(origin, press.anchor, minute);
  const next = apply(result);
  if (next && press.kind === "create") selected = newIndex(origin, next);
  render();
}

function onMove(event) {
  if (!press || event.pointerId !== press.id) return;
  press.lastY = event.clientY;
  if (press.kind === null) {
    const far = Math.hypot(event.clientX - press.x, event.clientY - press.y);
    if (press.touch) {
      if (far <= SWIPE_PX) return;
      if (press.index !== null && press.index === selected) begin(press.edge ? "resize" : "move");
      else begin("swipe");
    } else {
      if (far <= DRAG_PX) return;
      begin(press.index === null ? "create" : press.edge ? "resize" : "move");
    }
    return;
  }
  if (press.kind !== "swipe") drag();
}

function finish() {
  clearTimeout(press.timer);
  cancelAnimationFrame(press.frame);
  press = null;
}

function onUp(event) {
  if (!press || event.pointerId !== press.id) return;
  const { kind, index, origin, anchor } = press;
  finish();
  if (kind === null) {
    // A click or a tap: select the block, or put a two-hour block on free time.
    if (index !== null) return select(index);
    const next = apply(place(origin, anchor));
    if (next) select(newIndex(origin, next));
    return;
  }
  render();
}

/** The browser took the press for a scroll. Whatever was dragged so far stays. */
function onCancel(event) {
  if (!press || event.pointerId !== press.id) return;
  finish();
  render();
}

/** Once a touch is dragging a block, the page does not scroll under it. */
function onTouchMove(event) {
  if (press?.touch && press.kind && press.kind !== "swipe" && event.cancelable) event.preventDefault();
}

// ---- Opening and closing ----

function show() {
  const dialog = $("day-editor");
  // Beside the settings on a wide window, so both stay usable; over them otherwise.
  if (WIDE.matches) dialog.show();
  else dialog.showModal();
  document.body.classList.toggle("day-open", WIDE.matches);
}

export function openDayEditor(key) {
  day = key;
  selected = null;
  say("");
  if (!$("day-editor").open) show();
  render();
  scrollToStart();
}

function goTo(key) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) return;
  openDayEditor(key);
}

export function closeDayEditor() {
  if ($("day-editor").open) $("day-editor").close();
}

/** Draws the editor again from the plan, after anything changed it. */
export function refreshDayEditor() {
  if (press?.kind && press.kind !== "swipe") return;
  render();
}

export function initDayEditor(options) {
  host = options;
  const dialog = $("day-editor");
  const column = $("day-editor-day");
  const hours = $("day-editor-hours");
  for (let hour = 0; hour <= 24; hour++) {
    const line = el("div", "day-hour");
    line.style.top = px(hour * 60);
    line.append(el("span", "", `${String(hour).padStart(2, "0")}:00`));
    hours.append(line);
  }
  column.addEventListener("pointerdown", onDown);
  column.addEventListener("pointermove", onMove);
  column.addEventListener("pointerup", onUp);
  column.addEventListener("pointercancel", onCancel);
  column.addEventListener("touchmove", onTouchMove, { passive: false });
  column.addEventListener("contextmenu", (event) => event.preventDefault());
  // Keyboard: Enter selects a block and goes to its times; Delete or Backspace deletes it.
  column.addEventListener("click", (event) => {
    const node = event.target.closest(".day-block");
    if (!node || event.detail !== 0) return;
    select(Number(node.dataset.index));
    $("day-editor-start").focus();
  });
  column.addEventListener("keydown", (event) => {
    const node = event.target.closest(".day-block");
    if (!node || (event.key !== "Delete" && event.key !== "Backspace")) return;
    event.preventDefault();
    selected = Number(node.dataset.index);
    deleteSelected();
  });
  for (const id of ["day-editor-start", "day-editor-end"]) {
    $(id).addEventListener("change", typed);
    // Leaving a refused time shows the block's times again; the line above still says why.
    $(id).addEventListener("blur", render);
  }
  $("day-editor-delete").addEventListener("click", deleteSelected);
  $("day-editor-add").addEventListener("click", addBlock);
  $("day-editor-remove").addEventListener("click", () => {
    selected = null;
    say("");
    host.setBlocks(day, []);
  });
  $("day-editor-prev").addEventListener("click", () => goTo(shiftDay(day, -1)));
  $("day-editor-next").addEventListener("click", () => goTo(shiftDay(day, 1)));
  $("day-editor-date").addEventListener("change", () => goTo($("day-editor-date").value));
  $("day-editor-close").addEventListener("click", closeDayEditor);
  $("day-editor-discard").addEventListener("click", () => host.discard());
  // Opened beside the page there is no backdrop, so Esc is handled here.
  dialog.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !dialog.matches(":modal")) {
      event.preventDefault();
      closeDayEditor();
    }
  });
  dialog.addEventListener("close", () => {
    document.body.classList.remove("day-open");
    if (press) finish();
    selected = null;
  });
  // The window crossing the wide width while open: the editor moves beside or over the page.
  WIDE.addEventListener("change", () => {
    if (!dialog.open) return;
    const top = $("day-editor-scroll").scrollTop;
    const keep = selected;
    dialog.close();
    show();
    selected = keep;
    render();
    $("day-editor-scroll").scrollTop = top;
  });
}
