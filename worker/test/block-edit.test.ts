import assert from "node:assert/strict";
import test from "node:test";
import { readDayPlan } from "../src/plan.ts";
// @ts-ignore the browser file is plain JS with no types
import { create, move, place, resize, setExact, snap } from "../public/js/block-edit.js";

/**
 * Assumed shapes (the builder must match them):
 *   snap(minute) -> number
 *   move(blocks, i, start), resize(blocks, i, "start" | "end", minute), create(blocks, from, to),
 *   place(blocks, minute), setExact(blocks, i, start, end)
 *     -> { ok: true, blocks } or { ok: false, message }, like readBlocks in plan.js.
 * Blocks are [start, end] minutes, 0..1440, sorted. Inputs are never changed.
 */
type Block = [number, number];
type Result = { ok: true; blocks: Block[] } | { ok: false; message: string };

const MAX = 8;
const done = (result: Result): Block[] => {
  assert.equal(result.ok, true, JSON.stringify(result));
  return (result as { blocks: Block[] }).blocks;
};
const refused = (result: Result) => {
  assert.equal(result.ok, false, JSON.stringify(result));
  assert.equal(typeof (result as { message: string }).message, "string");
  assert.ok((result as { message: string }).message.length > 0);
};

/** Sorted, inside the day, no overlap, each at least `minLength`, at most MAX: what the server accepts. */
function assertValid(blocks: Block[], minLength = 1) {
  assert.ok(blocks.length <= MAX);
  let previousEnd = 0;
  for (const [start, end] of blocks) {
    assert.ok(Number.isInteger(start) && Number.isInteger(end));
    assert.ok(start >= previousEnd, `overlap or disorder in ${JSON.stringify(blocks)}`);
    assert.ok(end <= 1440 && start < 1440);
    assert.ok(end - start >= minLength, `too short in ${JSON.stringify(blocks)}`);
    previousEnd = end;
  }
}

test("snapping goes to the nearest 15 minutes", () => {
  assert.equal(snap(7), 0);
  assert.equal(snap(8), 15);
  assert.equal(snap(0), 0);
  assert.equal(snap(547), 540);
  assert.equal(snap(553), 555);
  assert.equal(snap(1440), 1440);
});

test("a move keeps the length", () => {
  const blocks: Block[] = [[540, 600], [900, 1020]];
  assert.deepEqual(done(move(blocks, 1, 960)), [[540, 600], [960, 1080]]);
  assert.deepEqual(done(move(blocks, 0, 300)), [[300, 360], [900, 1020]]);
});

test("a move is snapped", () => {
  assert.deepEqual(done(move([[540, 600]], 0, 547)), [[540, 600]]);
  assert.deepEqual(done(move([[540, 600]], 0, 553)), [[555, 615]]);
});

test("a move stops at both neighbours", () => {
  const blocks: Block[] = [[300, 360], [540, 600], [900, 960]];
  assert.deepEqual(done(move(blocks, 1, 1000)), [[300, 360], [840, 900], [900, 960]], "stops at the block after");
  assert.deepEqual(done(move(blocks, 1, 100)), [[300, 360], [360, 420], [900, 960]], "stops at the block before");
});

test("a move stops at both edges of the day", () => {
  const blocks: Block[] = [[540, 600], [900, 1020]];
  assert.deepEqual(done(move(blocks, 0, -200)), [[0, 60], [900, 1020]]);
  assert.deepEqual(done(move(blocks, 1, 1400)), [[540, 600], [1320, 1440]]);
});

test("a move does not change the input", () => {
  const blocks: Block[] = [[540, 600], [900, 1020]];
  const copy = JSON.parse(JSON.stringify(blocks));
  move(blocks, 0, 700);
  resize(blocks, 0, "end", 700);
  create(blocks, 100, 200);
  place(blocks, 100);
  setExact(blocks, 0, 100, 200);
  assert.deepEqual(blocks, copy);
});

test("a resize moves one edge", () => {
  const blocks: Block[] = [[540, 600]];
  assert.deepEqual(done(resize(blocks, 0, "end", 720)), [[540, 720]]);
  assert.deepEqual(done(resize(blocks, 0, "start", 480)), [[480, 600]]);
  assert.deepEqual(done(resize(blocks, 0, "end", 667)), [[540, 660]], "snapped");
});

test("a resize cannot cross a neighbour", () => {
  const blocks: Block[] = [[300, 360], [540, 600], [900, 960]];
  assert.deepEqual(done(resize(blocks, 1, "end", 2000)), [[300, 360], [540, 900], [900, 960]]);
  assert.deepEqual(done(resize(blocks, 1, "start", 0)), [[300, 360], [360, 600], [900, 960]]);
});

test("a resize stays inside the day", () => {
  const blocks: Block[] = [[540, 600]];
  assert.deepEqual(done(resize(blocks, 0, "end", 5000)), [[540, 1440]]);
  assert.deepEqual(done(resize(blocks, 0, "start", -300)), [[0, 600]]);
});

test("a resize cannot flip an edge past the other, and keeps 15 minutes", () => {
  const blocks: Block[] = [[540, 600]];
  assert.deepEqual(done(resize(blocks, 0, "start", 900)), [[585, 600]]);
  assert.deepEqual(done(resize(blocks, 0, "end", 100)), [[540, 555]]);
  assert.deepEqual(done(resize(blocks, 0, "end", 540)), [[540, 555]]);
});

test("a block can end at midnight but never start there", () => {
  assert.deepEqual(done(resize([[1380, 1410]], 0, "end", 1440)), [[1380, 1440]]);
  assert.deepEqual(done(move([[540, 600]], 0, 1440)), [[1380, 1440]]);
  const dragged = done(resize([[1380, 1440]], 0, "start", 1440));
  assertValid(dragged, 15);
  assert.deepEqual(dragged, [[1425, 1440]]);
  for (const result of [create([], 1440, 1440), place([], 1440), setExact([], 0, 1440, 1440)] as Result[]) {
    if (result.ok) assertValid(result.blocks, 15);
  }
  refused(setExact([[540, 600]], 0, 1440, 1440));
});

test("creating on taken time is refused", () => {
  const blocks: Block[] = [[540, 600]];
  refused(create(blocks, 560, 700));
  refused(create(blocks, 540, 700));
  refused(create(blocks, 590, 500));
});

test("a created block stays inside the gap it started in", () => {
  const blocks: Block[] = [[600, 660]];
  assert.deepEqual(done(create(blocks, 300, 900)), [[300, 600], [600, 660]]);
  assert.deepEqual(done(create(blocks, 900, 300)), [[600, 660], [660, 900]], "dragged upwards, it ends at the block before");
  assert.deepEqual(done(create(blocks, 120, 240)), [[120, 240], [600, 660]]);
});

test("a created block is snapped, in order, and at least 15 minutes", () => {
  const made = done(create([[600, 660]], 247, 353));
  assert.deepEqual(made, [[240, 360], [600, 660]]);
  for (const to of [300, 301, 307]) {
    const result = create([], 300, to) as Result;
    if (result.ok) assertValid(result.blocks, 15);
  }
});

test("touching blocks are allowed", () => {
  assert.deepEqual(done(create([[600, 660]], 660, 720)), [[600, 660], [660, 720]]);
  assert.deepEqual(done(create([[600, 660]], 540, 600)), [[540, 600], [600, 660]]);
  assert.deepEqual(done(setExact([[600, 660], [720, 780]], 1, 660, 780)), [[600, 660], [660, 780]]);
  assert.notEqual(readDayPlan({ dates: [{ day: "2026-12-01", blocks: [[600, 660], [660, 720]] }] }), "invalid");
});

test("a ninth block is refused", () => {
  const eight: Block[] = Array.from({ length: MAX }, (_, i) => [i * 60, i * 60 + 30] as Block);
  refused(create(eight, 600, 700));
  refused(place(eight, 700));
  const seven = eight.slice(0, 7);
  assert.equal(done(create(seven, 600, 700)).length, MAX);
});

test("a click on free time makes a two hour block", () => {
  assert.deepEqual(done(place([], 540)), [[540, 660]]);
  assert.deepEqual(done(place([[300, 360]], 540)), [[300, 360], [540, 660]]);
  assert.deepEqual(done(place([[1200, 1260]], 1200 - 120)), [[1080, 1200], [1200, 1260]]);
});

test("a placed block is cut down to the gap and the day", () => {
  assert.deepEqual(done(place([[660, 720]], 600)), [[600, 660], [660, 720]]);
  assert.deepEqual(done(place([], 1380)), [[1380, 1440]]);
  assert.deepEqual(done(place([[0, 60]], 120)), [[0, 60], [120, 240]]);
});

test("a click on taken time places nothing", () => {
  refused(place([[540, 600]], 560));
  refused(place([[540, 600]], 540));
});

test("typed times accept any minute", () => {
  assert.deepEqual(done(setExact([[540, 600]], 0, 547, 613)), [[547, 613]]);
  assert.deepEqual(done(setExact([[540, 600]], 0, 0, 1440)), [[0, 1440]]);
});

test("typed times are refused on overlap, or when the start is not before the end", () => {
  const blocks: Block[] = [[300, 360], [540, 600], [900, 960]];
  refused(setExact(blocks, 1, 350, 600));
  refused(setExact(blocks, 1, 540, 910));
  refused(setExact(blocks, 1, 100, 1000));
  refused(setExact(blocks, 1, 600, 600));
  refused(setExact(blocks, 1, 700, 650));
  refused(setExact(blocks, 1, -5, 100));
  refused(setExact(blocks, 1, 500, 1441));
});

test("a typed block keeps the blocks in order", () => {
  const blocks: Block[] = [[300, 360], [540, 600], [900, 960]];
  const result = done(setExact(blocks, 2, 400, 500));
  assert.deepEqual(result, [[300, 360], [400, 500], [540, 600]]);
});

// ---- The server's own check, independent of how these functions work ----

function random(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

function run(seed: number, withExact: boolean) {
  const next = random(seed);
  const int = (low: number, high: number) => low + Math.floor(next() * (high - low + 1));
  const minute = () => (next() < 0.1 ? [-50, 0, 1440, 1500][int(0, 3)] : int(0, 1440));
  let blocks: Block[] = [];
  for (let step = 0; step < 200; step++) {
    const i = blocks.length ? int(0, blocks.length - 1) : 0;
    let kind = int(0, withExact ? 5 : 4);
    if (blocks.length === 0 && (kind === 0 || kind === 1 || kind === 5)) kind = 2; // nothing to act on
    const before = JSON.stringify(blocks);
    let result: Result;
    if (kind === 0) result = move(blocks, i, minute());
    else if (kind === 1) result = resize(blocks, i, next() < 0.5 ? "start" : "end", minute());
    else if (kind === 2) result = create(blocks, minute(), minute());
    else if (kind === 3) result = place(blocks, minute());
    else if (kind === 4 && blocks.length && next() < 0.3) {
      blocks = blocks.filter((_, index) => index !== i);
      continue;
    } else if (kind === 4) continue;
    else result = setExact(blocks, i, minute(), minute());
    assert.equal(JSON.stringify(blocks), before, "the input is never changed");
    if (!result.ok) continue;
    blocks = result.blocks;
    assertValid(blocks, withExact ? 1 : 15);
    if (!withExact) for (const [start, end] of blocks) assert.ok(start % 15 === 0 && end % 15 === 0, `off the step: ${start}-${end}`);
    if (blocks.length) {
      const plan = readDayPlan({ dates: [{ day: "2026-12-01", blocks }] });
      assert.notEqual(plan, "invalid", `the server refuses ${JSON.stringify(blocks)} (seed ${seed}, step ${step})`);
    }
  }
}

test("random drags never give the server a plan it refuses", () => {
  for (let seed = 1; seed <= 200; seed++) run(seed, false);
});

test("random drags and typed times never give the server a plan it refuses", () => {
  for (let seed = 1001; seed <= 1200; seed++) run(seed, true);
});
