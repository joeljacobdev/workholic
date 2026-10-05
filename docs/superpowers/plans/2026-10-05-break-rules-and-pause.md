# Break rules and pause mode: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session, overtime and scheduled breaks next to the existing every-few-minutes break. Add a pause mode that keeps the Mac awake and counts nothing. Stop counting time while any cover is on screen.

**Architecture:**
- The pure logic lives in `WorkholicCore`, where XCTest covers it. All new state is additive and has defaults, so the existing 17 reminder tests pin today's behaviour.
- The AppKit layer wires that logic to the timers, the overlays and an IOKit power assertion.
- The worker stores new optional fields in the same `break_settings` row. It merges a partial PUT so older Macs cannot wipe them.

**Tech stack:** Swift 6 with AppKit and IOKit (macOS 14); a Cloudflare Worker with a Durable Object (TypeScript); vanilla JS for the web app.

**Spec:** `docs/superpowers/specs/2026-10-05-break-rules-and-pause-design.md`

## Global constraints

- Existing behaviour must not change, except that covered time is no longer counted. Simplifying existing code needs the user's permission.
- Wire format: `recurring_enabled`, `session_break {enabled,message,minutes,rest}`, `overtime {enabled,every_minutes,message,minutes,rest}`, `scheduled [{id,at:"HH:MM",message,minutes}]`.
- Limits:
  - messages: at most 200 characters
  - break length: 1 to 180 minutes
  - overtime `every_minutes`: 1 to 240
  - at most 10 `scheduled` entries
- Error codes: `bad_recurring_enabled`, `bad_session_break`, `bad_overtime`, `bad_scheduled`.
- The snooze is exactly 5 minutes, and the peek out of pause is exactly 5 minutes.

## Review focus

1. **An older Mac PUTs the old shape.** The stored new kinds must survive. Tested in the worker merge test (Task 1).
2. **A session break comes due while a recurring break is on screen.** It must be dropped when that break finishes, not shown straight after. Tested in Task 2.
3. **The Mac wakes partway through a scheduled window.** The break shows only what is left of the window, and never shows after the window ends. Tested in Task 3.
4. **The overtime counter while under the limit.** It must not grow. Tested in Task 2.
5. **The mouse is touched while a cover is up.** Nothing may be counted. Tested in Task 2 (gate).

---

### Task 1: Worker settings — new optional fields, defaults, merge

**Files:**
- Modify: `worker/src/breaks.ts`, `worker/src/user-account.ts`, `worker/src/index.ts`
- Test: `worker/test/breaks.test.ts`, `worker/test/api.integration.mjs`

**Interfaces:**
- Produces:
  - `parseBreakSettings(value) → {ok:true, settings: BreakSettingsInput} | {ok:false,error}`
  - `withBreakDefaults(stored: Partial<BreakSettings>) → BreakSettings`
  - `mergeBreakSettings(stored: BreakSettings, input: BreakSettingsInput) → BreakSettings`

- [ ] Step 1: Write failing tests in `breaks.test.ts`:
  - Valid new fields parse.
  - Each bad field gives its error code:
    - `recurring_enabled: "x"`
    - `session_break: {enabled:true, message:"", minutes:5, rest:true}`
    - `overtime.every_minutes: 0`
    - `scheduled[0].at: "25:00"`
    - 11 scheduled entries
  - `mergeBreakSettings(withBreakDefaults({...custom}), oldShapeInput)` keeps the custom `overtime`.
  - `DEFAULT_BREAKS` parses.
- [ ] Step 2: Run `npm test` and confirm the new tests fail.
- [ ] Step 3: Implement. `at` must match `/^([01]\d|2[0-3]):[0-5]\d$/` and `id` must match the UUID pattern.
  - `user-account.breaks` returns `withBreakDefaults(JSON.parse(row))`.
  - `setBreaks` reads the stored row, merges, then saves.
- [ ] Step 4: Run `npm test` and `npm run typecheck`. Both should pass.
- [ ] Step 5: Extend `api.integration.mjs`:
  - PUT with `overtime` enabled.
  - Then PUT the old shape.
  - Read back and assert `overtime.enabled === true`.
- [ ] Step 6: Commit.

### Task 2: Core — covered gate, break kinds, session and overtime breaks

**Files:**
- Modify: `macos/Sources/WorkholicCore/CaptureLogic.swift`, `macos/Sources/WorkholicCore/Reminder.swift`
- Test: `macos/Tests/WorkholicTests/CaptureLogicTests.swift`, `macos/Tests/WorkholicTests/BreakRulesTests.swift` (new)

**Interfaces (produced):**

```swift
public enum BreakKind: String, Sendable, Equatable, Codable { case recurring, session, overtime, scheduled }
// DueBreak: + kind: BreakKind = .recurring
// ActiveBreak: + kind: BreakKind = .recurring, + scheduleId: String? = nil
// ReminderState: + overtimeMs: Int64 = 0, + extraDue: DueBreak? = nil
// ReminderTick: + overLimit: Bool = false, + overtimeAfterMs: Int64 = 0,
//               + overtimeBreak: DueBreak? = nil, + sessionBreak: DueBreak? = nil
// GateSample: + covered: Bool = false
```

Rules, each added at an existing reset point:

| Where | Change |
|---|---|
| `recordSession`, when it first notifies | `if let b = tick.sessionBreak, state.extraDue == nil { state.extraDue = b }` |
| Sleep or dark-display branch | `overtimeMs = 0`. Clear `extraDue` if it is a rest. |
| Attended branch | If `overLimit && extraDue == nil`, add to `overtimeMs`. When it reaches `overtimeAfterMs` (> 0) and `overtimeBreak` is non-nil, set `extraDue`. |
| Away reset | `overtimeMs = 0`, `extraDue = nil` |
| End of step | If `extraDue`, no active break and not on a call, open it with `.beginBreak` and clear `extraDue`. |
| `finishBreakState` | `overtimeMs = 0`, `extraDue = nil` |

- [ ] Step 1: Write failing tests:
  - **Gate:** `covered` makes `attending` false.
  - **Session:** a session break opens when the budget is reached; waits on a call; is dropped by sleep when it is a rest; is kept through sleep when it is an activity break.
  - **Overtime:** does not grow under the limit; opens at the threshold; is reset when a recurring break is finished.
  - **Interaction:** a session break due while a recurring break is up is gone after that break finishes.
- [ ] Step 2: Run `swift test` and confirm the new tests fail to compile or fail.
- [ ] Step 3: Implement the rules.
- [ ] Step 4: Run `swift test`. All 35 old tests and the new ones should pass.
- [ ] Step 5: Commit.

### Task 3: Core — scheduled breaks

**Files:**
- Create: `macos/Sources/WorkholicCore/ScheduledBreaks.swift`
- Test: `macos/Tests/WorkholicTests/ScheduledBreaksTests.swift`

**Interfaces (produced):**

```swift
public struct ScheduledBreak: Sendable, Equatable { id: String; startMinute: Int; durationMs: Int64; message: String }
public func clockMinute(_ text: String) -> Int?                      // "13:05" -> 785
public func dueScheduled(_ entries: [ScheduledBreak], msIntoDay: Int64, day: String,
                         handled: [String: String]) -> (entry: ScheduledBreak, remainingMs: Int64)?
public func beginScheduledBreak(state: ReminderState, entry: ScheduledBreak, remainingMs: Int64) -> (ReminderState, [ReminderNotice])
public func snoozeBreak(state: ReminderState) -> (ReminderState, ActiveBreak?)   // removes the active break without finishing it
```

- [ ] Step 1: Write failing tests:
  - `clockMinute` on valid and invalid input.
  - The window edges: the start is inside, the end is outside.
  - The remaining time after a late start.
  - A handled entry for today is skipped, but the same entry is due on another day.
  - The earliest-starting entry wins.
  - Beginning a break while one is active does nothing.
  - Snoozing keeps the stretches and returns the break.
- [ ] Step 2: Confirm the tests fail.
- [ ] Step 3: Implement.
- [ ] Step 4: Run `swift test` and confirm everything passes.
- [ ] Step 5: Commit.

### Task 4: Mac plan model and payload

**Files:** `macos/Sources/Workholic/BreakPlan.swift`, `macos/Sources/Workholic/ApiClient.swift`

- `SessionBreakRule`, `OvertimeRule` and `ScheduledItem` are Codable.
- `BreakPlan` gains `recurringEnabled`, `session`, `overtime` and `scheduled`, all read with `decodeIfPresent` and defaults.
- `breakAfterMs` and `due` also require `recurringEnabled`.
- New: `sessionDue`, `overtimeDue`, `overtimeAfterMs` and `scheduledEntries`.
- The payload gains optional fields; `adopting` keeps the local values when the remote ones are nil.
- Verify with `swift build`, then commit.

### Task 5: Overlays — snooze button, pause cover, power assertion

**Files:**
- Modify: `BreakOverlay.swift`, adding `onSnooze`, and `show(..., snoozable: Bool)`, which shows "5 more minutes".
- Create: `PauseOverlay.swift`:
  - a black screen-saver-level window on every display
  - dim text
  - a `CABasicAnimation` on the opacity of a dot layer: 4 seconds, autoreverse, `preferredFrameRateRange` 4 to 10 fps
  - a minute timer with tolerance for the elapsed time
  - "Unpause for 5 minutes" and "Unpause" buttons
- Create: `PowerAssertion.swift`, which wraps `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)` with `hold()` and `release()`.
- Verify with `swift build`, then commit.

### Task 6: AppModel wiring and menu

**Files:** `AppModel.swift`, `main.swift`

- **Gate:** `covered: covering || pauseCovered`, and `store.seal()` whenever a cover appears.
- **Reminder tick:**
  - `onCall: onCall || paused`
  - `overLimit`, which uses a new `usedTodayMs` and is computed only when overtime is on
  - `sessionBreak` and `overtimeBreak`
- **`deliver`:** advance the cursor only for `.recurring`.
- **Scheduled breaks:** checked each tick from `msIntoDay` (calendar components), `civilDay`, and handled entries stored in UserDefaults under `scheduledHandled`.
  - A snooze is held in `snoozed` and `snoozeUntil`.
  - The countdown for a scheduled break uses the wall-clock elapsed time.
- **Pause:** `pause()`, `peek()` and `unpause()`.
  - Turning pause on calls `skipBreak` and hides the snooze.
  - The peek timer lasts 5 minutes.
- **Menu:** "Pause (keep awake, not counted)" or "Unpause". The status badge reads "Paused".
- **Menu lines:** "Next pause" only when `recurringEnabled`, and one line for each pending or snoozed break.
- Verify with `swift build`, then commit.

### Task 7: Editors — Mac tabs and web sections

**Files:** `BreakEditor.swift`, `worker/public/index.html`, `app.js`, `app.css`

- **Mac editor:** an `NSTabView`.
  - Tab 1 holds the existing controls unchanged, plus an "Every few minutes" checkbox.
  - Tabs 2 to 4 hold the session, overtime and scheduled forms.
  - Save validates against the same limits as the worker.
- **Web:** fieldsets for each kind, with a scheduled list using a time input, and error messages for the new codes.
- Verify with `swift build`, `npm test` and `npm run typecheck`, then commit.

### Task 8: Ship

- [ ] Run `swift test`, `npm test`, `npm run typecheck` and `npm run test:api`.
- [ ] Run `make install`, which quits the running app, bumps the version, builds and installs.
- [ ] Run `npm --prefix worker run deploy`.
- [ ] Fast-forward `main` and push.
