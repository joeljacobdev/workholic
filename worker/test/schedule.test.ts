import assert from "node:assert/strict";
import test from "node:test";
import { readShutdownSchedule } from "../src/schedule.ts";

test("a time is enough; the limit and the command are optional", () => {
  assert.deepEqual(readShutdownSchedule({ after: "22:00" }), { after: "22:00", after_limit: false, command: null });
  assert.deepEqual(readShutdownSchedule({ after: "21:30", after_limit: true, command: "last-call-end.sh" }), {
    after: "21:30",
    after_limit: true,
    command: "last-call-end.sh",
  });
  assert.deepEqual(readShutdownSchedule({ after: "00:00", command: "" }), { after: "00:00", after_limit: false, command: null });
});

test("null turns it off", () => {
  assert.equal(readShutdownSchedule(null), null);
});

test("the time must be 24-hour HH:MM", () => {
  for (const after of ["24:00", "9:00", "12:60", "10pm", "", undefined, 2200]) {
    assert.equal(readShutdownSchedule({ after }), "invalid", String(after));
  }
});

test("the command is a bare script name, never a path or shell", () => {
  for (const command of ["../evil", "a/b", "/bin/sh", "rm -rf ~", "x;y", "$(id)", ".hidden", "a..b", 7, "x".repeat(101)]) {
    assert.equal(readShutdownSchedule({ after: "22:00", command }), "invalid", String(command));
  }
});

test("other shapes are refused", () => {
  assert.equal(readShutdownSchedule("22:00"), "invalid");
  assert.equal(readShutdownSchedule([]), "invalid");
  assert.equal(readShutdownSchedule({ after: "22:00", after_limit: "yes" }), "invalid");
});
