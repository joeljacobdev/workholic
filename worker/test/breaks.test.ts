import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_BREAKS, mergeBreakSettings, parseBreakSettings, withBreakDefaults } from "../src/breaks.ts";

const item = { id: "6F9619FF-8B86-4011-B42D-00C04FC964FF", message: "  Stretch.  ", minutes: 3, rest: false };

test("valid settings are kept and messages are trimmed", () => {
  const result = parseBreakSettings({ enabled: false, every_minutes: 50, items: [item] });
  assert.ok(result.ok);
  assert.equal(result.settings.enabled, false);
  assert.equal(result.settings.items[0].message, "Stretch.");
});

test("the default settings pass their own validation", () => {
  assert.ok(parseBreakSettings(DEFAULT_BREAKS).ok);
});

test("bad shapes are rejected with a specific error", () => {
  const cases: Array<[unknown, string]> = [
    [null, "bad_breaks"],
    [{ every_minutes: 15, items: [item] }, "bad_enabled"],
    [{ enabled: true, every_minutes: 0, items: [item] }, "bad_every_minutes"],
    [{ enabled: true, every_minutes: 1.5, items: [item] }, "bad_every_minutes"],
    [{ enabled: true, every_minutes: 15, items: [] }, "bad_items"],
    [{ enabled: true, every_minutes: 15, items: Array(21).fill(item) }, "bad_items"],
    [{ enabled: true, every_minutes: 15, items: [{ ...item, id: "x" }] }, "bad_item_id"],
    [{ enabled: true, every_minutes: 15, items: [{ ...item, message: "   " }] }, "bad_item_message"],
    [{ enabled: true, every_minutes: 15, items: [{ ...item, message: "x".repeat(201) }] }, "bad_item_message"],
    [{ enabled: true, every_minutes: 15, items: [{ ...item, minutes: 181 }] }, "bad_item_minutes"],
    [{ enabled: true, every_minutes: 15, items: [{ ...item, rest: "yes" }] }, "bad_item_rest"],
  ];
  for (const [input, error] of cases) {
    const result = parseBreakSettings(input);
    assert.equal(result.ok, false, JSON.stringify(input));
    if (!result.ok) assert.equal(result.error, error);
  }
});

const base = { enabled: true, every_minutes: 15, items: [item] };
const lunch = { id: "7f9619ff-8b86-4011-b42d-00c04fc964ff", at: "13:00", message: " Lunch. ", minutes: 45 };
const overtime = { enabled: true, every_minutes: 20, message: "Past the limit.", minutes: 5, rest: true };
const session = { enabled: true, message: "Session done.", minutes: 5, rest: false };

test("the newer break kinds parse and are optional", () => {
  const result = parseBreakSettings({ ...base, recurring_enabled: false, session_break: session, overtime, scheduled: [lunch] });
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(result.settings.recurring_enabled, false);
  assert.deepEqual(result.settings.session_break, session);
  assert.deepEqual(result.settings.overtime, overtime);
  assert.equal(result.settings.scheduled?.[0].message, "Lunch.");
  const old = parseBreakSettings(base);
  assert.ok(old.ok);
  if (old.ok) assert.equal(old.settings.overtime, undefined);
});

test("bad newer fields are rejected with a specific error", () => {
  const cases: Array<[unknown, string]> = [
    [{ ...base, recurring_enabled: "yes" }, "bad_recurring_enabled"],
    [{ ...base, session_break: { ...session, message: " " } }, "bad_session_break"],
    [{ ...base, session_break: { ...session, minutes: 0 } }, "bad_session_break"],
    [{ ...base, overtime: { ...overtime, every_minutes: 0 } }, "bad_overtime"],
    [{ ...base, overtime: { ...overtime, rest: 1 } }, "bad_overtime"],
    [{ ...base, scheduled: [{ ...lunch, at: "25:00" }] }, "bad_scheduled"],
    [{ ...base, scheduled: [{ ...lunch, at: "9:00" }] }, "bad_scheduled"],
    [{ ...base, scheduled: [{ ...lunch, id: "x" }] }, "bad_scheduled"],
    [{ ...base, scheduled: [{ ...lunch, minutes: 181 }] }, "bad_scheduled"],
    [{ ...base, scheduled: Array(11).fill(lunch) }, "bad_scheduled"],
    [{ ...base, scheduled: "lunch" }, "bad_scheduled"],
  ];
  for (const [input, error] of cases) {
    const result = parseBreakSettings(input);
    assert.equal(result.ok, false, JSON.stringify(input));
    if (!result.ok) assert.equal(result.error, error);
  }
});

test("stored records from before the newer kinds get defaults", () => {
  const filled = withBreakDefaults({ enabled: false, every_minutes: 50, items: [item] });
  assert.equal(filled.enabled, false);
  assert.equal(filled.recurring_enabled, true);
  assert.equal(filled.session_break.enabled, false);
  assert.equal(filled.overtime.enabled, false);
  assert.deepEqual(filled.scheduled, []);
});

test("an older Mac saving the old shape keeps the newer kinds", () => {
  const stored = withBreakDefaults({ ...base, overtime, scheduled: [lunch] });
  const parsed = parseBreakSettings({ ...base, every_minutes: 30 });
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  const merged = mergeBreakSettings(stored, parsed.settings);
  assert.equal(merged.every_minutes, 30);
  assert.deepEqual(merged.overtime, overtime);
  assert.equal(merged.scheduled.length, 1);
});
