import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_BREAKS, parseBreakSettings } from "../src/breaks.ts";

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
