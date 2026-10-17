import assert from "node:assert/strict";
import test from "node:test";
import { readShutdownSchedule } from "../src/schedule.ts";

test("a clock time, with an optional script", () => {
  assert.deepEqual(readShutdownSchedule({ when: "time", after: "22:00" }), { when: "time", after: "22:00", delay_minutes: 0, command: null });
  assert.deepEqual(readShutdownSchedule({ when: "time", after: "21:30", command: "last-call-end.sh" }), {
    when: "time",
    after: "21:30",
    delay_minutes: 0,
    command: "last-call-end.sh",
  });
  assert.deepEqual(readShutdownSchedule({ when: "time", after: "00:00", command: "" }), { when: "time", after: "00:00", delay_minutes: 0, command: null });
});

test("after the limit, with an optional delay", () => {
  assert.deepEqual(readShutdownSchedule({ when: "limit" }), { when: "limit", after: null, delay_minutes: 0, command: null });
  assert.deepEqual(readShutdownSchedule({ when: "limit", delay_minutes: 30, after: "22:00", command: "cal" }), {
    when: "limit",
    after: null,
    delay_minutes: 30,
    command: "cal",
  });
  for (const delay_minutes of [-1, 1.5, 721, "30"]) {
    assert.equal(readShutdownSchedule({ when: "limit", delay_minutes }), "invalid", String(delay_minutes));
  }
});

test("the first version's shape is a clock time", () => {
  assert.deepEqual(readShutdownSchedule({ after: "22:00", after_limit: true }), { when: "time", after: "22:00", delay_minutes: 0, command: null });
});

test("null turns it off", () => {
  assert.equal(readShutdownSchedule(null), null);
});

test("a clock time must be 24-hour HH:MM", () => {
  for (const after of ["24:00", "9:00", "12:60", "10pm", "", undefined, 2200]) {
    assert.equal(readShutdownSchedule({ when: "time", after }), "invalid", String(after));
  }
});

test("the command is a bare script name, never a path or shell", () => {
  for (const command of ["../evil", "a/b", "/bin/sh", "rm -rf ~", "x;y", "$(id)", ".hidden", "a..b", 7, "x".repeat(101)]) {
    assert.equal(readShutdownSchedule({ when: "time", after: "22:00", command }), "invalid", String(command));
  }
});

test("other shapes are refused", () => {
  assert.equal(readShutdownSchedule("22:00"), "invalid");
  assert.equal(readShutdownSchedule([]), "invalid");
  assert.equal(readShutdownSchedule({ when: "sunset" }), "invalid");
});
