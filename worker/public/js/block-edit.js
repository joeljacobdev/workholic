// The rules for one date's time blocks as the calendar edits them, and how their times are written.
// No page code here, so the tests load it with Node. Blocks are [start, end] minutes from 0 to 1440,
// where 1440 is midnight at the end of the day; they are kept sorted, and blocks may touch, as the
// server allows (src/plan.ts readBlocks). Every function returns a new list and never changes its input.

export const DAY_MINUTES = 1440;
export const MAX_BLOCKS = 8;
/** Dragging moves in steps of this many minutes, and a dragged block is at least this long. */
export const STEP = 15;
/** A click on free time makes a block this long, cut down to the free time. */
const PLACE_MINUTES = 120;

const TOO_MANY = `${MAX_BLOCKS} blocks is the most for a day.`;
const NO_ROOM = "There is no room for a block here.";

export const hhmm = (minute) => `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
export const endText = (minute) => (minute === DAY_MINUTES ? "midnight" : hhmm(minute));
export const blockText = ([start, end]) => `${hhmm(start)}–${endText(end)}`;
export const plannedMs = (blocks) => blocks.reduce((sum, [start, end]) => sum + (end - start) * 60_000, 0);

/** "HH:MM" as minutes. An end of 00:00 is midnight at the end of the day. */
export function minutes(text, isEnd) {
  if (!/^\d{2}:\d{2}$/.test(text)) return null;
  const [hours, mins] = text.split(":").map(Number);
  const value = hours * 60 + mins;
  return isEnd && value === 0 ? DAY_MINUTES : value;
}

export const snap = (minute) => Math.round(minute / STEP) * STEP;

const clamp = (value, low, high) => Math.min(Math.max(value, low), high);
const inDay = (minute) => clamp(minute, 0, DAY_MINUTES);
const copy = (blocks) => blocks.map(([start, end]) => [start, end]);
const sorted = (blocks) => blocks.sort((a, b) => a[0] - b[0]);
const overlapText = (block) => `Overlaps ${blockText(block)}.`;

/** Where block `i` may go: from the end of the one before it to the start of the one after. */
function room(blocks, i) {
  return [i > 0 ? blocks[i - 1][1] : 0, i < blocks.length - 1 ? blocks[i + 1][0] : DAY_MINUTES];
}

/** The block a minute falls in, or null. A block's end is free time. */
const blockAt = (blocks, minute) => blocks.find(([start, end]) => start <= minute && minute < end) ?? null;

/** The free time around a minute that no block covers: from the last end before it to the next start. */
function gapAt(blocks, minute) {
  let low = 0;
  let high = DAY_MINUTES;
  for (const [start, end] of blocks) {
    if (end <= minute) low = Math.max(low, end);
    if (start > minute) high = Math.min(high, start);
  }
  return [low, high];
}

/** A new block from a free minute, or why not: on taken time, or a ninth. */
function freeAt(blocks, minute) {
  if (blocks.length >= MAX_BLOCKS) return { ok: false, message: TOO_MANY };
  const raw = inDay(minute);
  const at = snap(raw);
  const taken = blockAt(blocks, raw) ?? blockAt(blocks, at);
  if (taken) return { ok: false, message: overlapText(taken) };
  return { ok: true, at, gap: gapAt(blocks, at) };
}

function added(blocks, start, end, low, high) {
  if (end - start < STEP) {
    // Too short against the gap's edge: it grows the other way, as far as the gap allows.
    if (end === high) start = Math.max(low, end - STEP);
    else end = Math.min(high, start + STEP);
  }
  if (end - start < STEP || start >= DAY_MINUTES) return { ok: false, message: NO_ROOM };
  return { ok: true, blocks: sorted([...copy(blocks), [start, end]]) };
}

/** Block `i` moved to start at `start`, the same length, stopping at its neighbours and the day's edges. */
export function move(blocks, i, start) {
  const [low, high] = room(blocks, i);
  const length = blocks[i][1] - blocks[i][0];
  const next = copy(blocks);
  const at = clamp(snap(start), low, high - length);
  next[i] = [at, at + length];
  return { ok: true, blocks: next };
}

/** One edge of block `i` moved to `minute`. It stops at a neighbour, and the block keeps one step. */
export function resize(blocks, i, edge, minute) {
  const [low, high] = room(blocks, i);
  const [start, end] = blocks[i];
  const at = snap(minute);
  const next = copy(blocks);
  next[i] = edge === "start"
    ? [Math.max(Math.min(at, end - STEP), low), end]
    : [start, Math.min(Math.max(at, start + STEP), high)];
  return { ok: true, blocks: next };
}

/** A block dragged from `from` to `to`, either way. It starts on free time and stays in that gap. */
export function create(blocks, from, to) {
  const free = freeAt(blocks, from);
  if (!free.ok) return free;
  const [low, high] = free.gap;
  const other = snap(inDay(to));
  return other >= free.at
    ? added(blocks, free.at, Math.min(Math.max(other, free.at + STEP), high), low, high)
    : added(blocks, Math.max(Math.min(other, free.at - STEP), low), free.at, low, high);
}

/** A click on free time: a two-hour block from there, cut down to the gap. */
export function place(blocks, minute) {
  const free = freeAt(blocks, minute);
  if (!free.ok) return free;
  const [low, high] = free.gap;
  return added(blocks, free.at, Math.min(free.at + PLACE_MINUTES, high), low, high);
}

/** Typed times for block `i`: any whole minutes in the day, start before end, not over another block. */
export function setExact(blocks, i, start, end) {
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end > DAY_MINUTES) {
    return { ok: false, message: "Enter times within the day." };
  }
  if (start >= end) return { ok: false, message: "The end must come after the start." };
  const others = copy(blocks).filter((_, index) => index !== i);
  const taken = others.find(([otherStart, otherEnd]) => otherStart < end && start < otherEnd);
  if (taken) return { ok: false, message: overlapText(taken) };
  return { ok: true, blocks: sorted([...others, [start, end]]) };
}
