# Per-Mac Shutdown Schedule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the day plan give each Mac its own shutdown schedule (off, at a time, after the limit, when the last block ends, plus script), or keep one schedule for every Mac.

**Architecture:** The plan gains `scope` ("all" | "each") and `each`, a map from device id to a shutdown choice with the same four fields the plan already holds (`shutdown`, `at`, `delay_minutes`, `command`). The server validates each entry with the rules the plan's own shutdown uses, and works out the legacy shutdown per device. The Mac picks its own entry when the scope is "each". The web form shows one row per enrolled Mac under "each".

**Tech Stack:** Cloudflare Worker (TypeScript, node:test), vanilla JS web app, Swift (XCTest).

**Spec:** The design in the conversation of 2026-10-27: per-Mac schedules; plans saved before read as "same on every Mac"; new accounts start on "each"; rows live in Settings › Your day with this Mac marked inside the app window; "Shut down now" in Devices is unchanged.

## Global Constraints

- An entry with `shutdown: "off"` is not stored; absent means off.
- At most `MAX_DEVICES_PER_REQUEST` (50) entries; keys are UUIDs.
- `limit` only in limit mode, `last_block` only in planner mode, as today.
- Plans without `scope` read as `"all"`; `DEFAULT_PLAN.scope` is `"each"`.

## Review Focus

- A Mac not in `each` under scope "each": no shutdown, legacy field null. (Task 1 test)
- Scope "all" with entries in `each`: entries dropped on read. (Task 1 test)
- A plan from an older server with no `scope` decodes on the Mac as `.all`. (Task 3 test)
- A device enrolled after the plan was saved: row appears unset, saving leaves it off. (Task 5, by construction)
- Within-the-hour warning names only the Macs whose time is within the hour. (Task 5)

---

### Task 1: Worker plan model

**Files:** Modify `worker/src/plan.ts`; Test `worker/test/plan.test.ts`.

**Produces:** `interface MacShutdown { shutdown; at; delay_minutes; command }`, `DayPlan.scope`, `DayPlan.each: Record<string, MacShutdown>`, `shutdownFor(plan, deviceId): MacShutdown`, `legacyShutdown(plan, day, weekend, deviceId?)`.

- [ ] Tests: scope defaults, each validated, off dropped, all drops each, legacy per device, unknown device null.
- [ ] Implement with a shared `readShutdown(record, mode)` used for the plan and each entry.
- [ ] `npm --prefix worker test` passes. Commit.

### Task 2: Serve the legacy shutdown per device

**Files:** Modify `worker/src/user-account.ts:568`.

- [ ] Pass `device.deviceId` to `legacyShutdown`. Typecheck. Commit with Task 3.

### Task 3: Mac plan model

**Files:** Modify `macos/Sources/WorkholicCore/AccountPlan.swift`; Test `macos/Tests/WorkholicTests/AccountPlanTests.swift`.

**Produces:** `AccountPlan.Scope`, `AccountPlan.MacShutdown`, `plan.scope`, `plan.each`, `planShutdownRule(_:blocks:deviceId:)`.

- [ ] Tests: decode with and without scope; each entry picked by device id; absent entry nil; validation of entries.
- [ ] Implement. `swift test` passes. Commit.

### Task 4: The Mac uses its own entry

**Files:** Modify `macos/Sources/Workholic/AppModel.swift:183` and `macState`.

- [ ] `todayShutdownRule` passes `deviceId`; `macState` gains `"deviceId"`. Build. Commit.

### Task 5: Web form

**Files:** Modify `worker/public/index.html`, `worker/public/js/plan.js`, `worker/public/js/devices.js`, `worker/public/app.css`.

- [ ] Scope select `plan-scope`; under "each", `plan-each` holds one row per Mac from `/v1/stats` device_info (`setPlanDevices` called from `loadDevices`), this Mac marked inside the app.
- [ ] `read()` builds `each`; `fill()` sets rows; `soonWarnings` names Macs.
- [ ] Commit.

### Task 6: Docs and release

- [ ] Update `docs/breaks-and-sessions.md` "Your day" section.
- [ ] Tests, typecheck, build, install, deploy worker, push.
