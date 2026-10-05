# Break rules and pause mode

**Date:** 2026-10-05
**Status:** Approved for build (the user chose "spec, plan, and build" while away)

## Intent

The user wants several kinds of break running side by side, and a way to step away while an agent works. During that time the Mac must stay awake and the time must not be counted.

What the user said:

- There are several kinds of break, each with its own message and length, and more than one can be active at once.
  - **Every few minutes.** This is today's break, and it stays exactly as it is.
  - **After a session.** When a session budget runs out, a break covers the screen.
  - **Past the daily limit.** Nothing happens before the limit. Once the day's limit is crossed and work continues, overtime runs in sessions of a length the user picks, with a break after each one.
  - **At a set time.** For example, lunch at 13:00 for 45 minutes. This screen shows **"5 more minutes"** and **Skip**.
- **Pause mode.** A full-screen cover with two buttons, **Unpause** and **Unpause for 5 minutes**.
  - The screen stays on and the Mac stays awake, so an agent can keep working.
  - None of it counts.
  - It should be calm and animated, but low-power and near-black.
- No time counts towards this Mac's screen time while a break screen or the pause screen is on it.
- The existing code is correct. Simplifying it needs the user's permission first. This design therefore adds to the code and does not rewrite it.

Assumptions (the user did not say these):

- "The daily limit" is whatever the active budget mode treats as the ceiling, using the same arithmetic the menu-bar gauge uses:
  - **Fixed mode:** the standing limit, compared with the larger of this Mac's time and the synced total.
  - **Dynamic mode:** today's task total, compared with this Mac's time.
- Pause mode belongs to one Mac. It is not synced and does not survive quitting the app.
- Settings for the new break kinds sync through the existing `/v1/breaks` record, like today's break settings.

## Behaviour

### One break on screen at a time

Every kind uses the existing `ActiveBreak` path. They all share the overlay, the one-second countdown, hiding during a call, and Skip with Esc.

- If a second break becomes due while one is on screen, it waits.
- Finishing or skipping **any** break counts as a break taken:
  - The every-few-minutes stretch resets, as it does today.
  - The overtime stretch resets.
  - A session break that was still waiting is dropped.

  This stops breaks from running back to back.
- A scheduled break whose time window is still open shows after the current break ends, with whatever time is left in its window.

### Every few minutes (unchanged)

The existing `enabled`, `every_minutes` and `items` settings, with the same logic in `reminderStep`. One new switch, `recurring_enabled` (default true), turns this kind off without turning off the others. The existing `enabled` stays the master switch: when it is off, no break of any kind opens. Existing records are unaffected, because there was only ever this one kind.

### After a session

Settings are `session_break = { enabled, message, minutes, rest }`. The default is off, with "Session done. Step away from the screen.", 5 minutes, rest.

When `recordSession` finds the session budget reached, the existing notification still fires. If the session break is on, the break also becomes *pending*.

### Past the daily limit (overtime)

Settings are `overtime = { enabled, every_minutes, message, minutes, rest }`. The default is off, every 25 minutes, "You are past today's limit. Step away.", 5 minutes, rest.

- While the day is over its limit, each attended millisecond also adds to `overtimeMs`.
- When `overtimeMs` reaches `every_minutes`, an overtime break becomes pending.
- Under the limit, `overtimeMs` does not grow.
- The first overtime break therefore comes `every_minutes` after the limit is crossed. It does not come at the moment of crossing.

### Pending breaks (session and overtime)

There is one pending slot, `ReminderState.extraDue`. It opens on the first tick where all of these hold:
- no break is active
- no call is on and pause mode is off
- the display is awake

The slot is cleared in these cases:
- **Sleep or the display going dark:** cleared if the pending break is a rest. That already was the rest, the same rule the every-few-minutes kind uses. An activity break is kept.
- **The away reset** (5 minutes of nothing): cleared. Today this also clears a held every-few-minutes break.
- **Any break finishing:** cleared.

`overtimeMs` resets wherever `stretchMs` resets.

If a session break and an overtime break come due together, the slot keeps whichever arrived first, and finishing that break clears the other.

### At a set time (scheduled)

Settings are `scheduled = [{ id, at: "HH:MM", message, minutes }]`, with up to 10 entries and 1 to 180 minutes each.

- Each entry has a window from `at` to `at + minutes` in this Mac's local time, once per civil day.
- It opens when all of these hold:
  - the time is inside the window
  - it has not been handled today
  - no break is active
  - no call is on and pause mode is off
  - the display is awake

  It then shows the **time left in the window**. If the Mac wakes at 13:30 for a 13:00 to 13:45 lunch, the break shows 15 minutes.
- The countdown uses the wall clock, so lunch ends on time even across sleep. A call hides it and holds its time, the same as every other kind.
- A scheduled break is never a rest. A dark display does not end lunch.
- **5 more minutes** hides the break. Five minutes later it reopens with the time it had left, so the window moves 5 minutes later. It can be pressed again.
- **Skip** ends it for today.
- Handled entries (`id → day`) are stored in UserDefaults, so restarting the app does not show a skipped lunch again.

### Pause mode

- **Menu bar:**
  - "Pause (keep awake, not counted)" turns pause mode on.
  - While paused, the item reads "Unpause".
- **Turning it on:**
  - The current interval is sealed.
  - Any break on screen is counted as taken (through `skipBreak`).
  - An IOKit assertion `PreventUserIdleDisplaySleep` is taken. It keeps both the display and the system awake.
  - The pause cover shows on every display.
- **While paused:**
  - The capture gate counts nothing, because the screen is covered.
  - The reminder sees pause mode the way it sees a call, so nothing opens. The elapsed time builds up as "away", so stretches reset after 5 minutes as they would if you had walked off.
  - Scheduled breaks wait. If their window is still open when you unpause, they show then.
- **Unpause for 5 minutes:**
  - The cover hides and counting resumes normally.
  - The assertion is kept.
  - After 5 minutes the cover returns: the interval is sealed and any break on screen is counted as taken.
- **Unpause:** the assertion is released and the cover hides.
- **Cover design:**
  - A pure black window above everything, at screen-saver level, on every display.
  - The word "Paused" in dim grey.
  - The line "Your Mac stays awake. This time is not counted."
  - "Paused for 1h 12m", updated once a minute by a timer with tolerance.
  - Two plain buttons.
  - One slow breathing dot made with Core Animation: the opacity eases between 0.12 and 0.45 over 4 seconds, with a preferred frame rate of 10 fps. The window server runs it, with no per-frame app work.
  - No countdown timer runs.
  - The app does not change the system brightness: the private APIs for that are fragile.
- **Limit:** closing the lid still sleeps a laptop, unless it is on power with an external display. An assertion cannot stop that.

### Covered time is not counted

`GateSample` gains `covered: Bool` (default false), and `attending` returns false when it is set. The app sets it while a break or the pause cover is visible. While a call hides a break, the break is not visible, so time counts.

When a cover appears, the open interval is sealed at once. At most one sample period (20 seconds) before the cover is lost; nothing is invented.

## Sync compatibility

All the new fields are optional on the wire.

- **Worker `PUT /v1/breaks`:** a field missing from the body keeps its stored value. An older Mac that saves its old-shape plan therefore does not wipe the new kinds.
- **Worker `GET`:** returns every field, filling defaults where none are stored.
- **Mac decoder:** missing fields fall back to defaults.
- **Older Macs:** they ignore the unknown keys.

Validation errors:

| Error | Field |
|---|---|
| `bad_recurring_enabled` | `recurring_enabled` |
| `bad_session_break` | `session_break` |
| `bad_overtime` | `overtime` |
| `bad_scheduled` | `scheduled` |

## Units and files

| Unit | File | Change |
|---|---|---|
| Settings parsing | `worker/src/breaks.ts` | Add the optional fields, their defaults, and a merge of stored values into a partial PUT |
| Account store | `worker/src/user-account.ts`, `worker/src/index.ts` | `setBreaks` merges with the stored record |
| Web settings | `worker/public/index.html`, `app.js`, `app.css` | New sections for "Every few minutes", "After a session", "Past the limit" and "At set times" |
| Gate | `WorkholicCore/CaptureLogic.swift` | `covered` |
| Reminder core | `WorkholicCore/Reminder.swift` | `BreakKind` on `ActiveBreak`; `extraDue` and `overtimeMs` on the state; `overLimit`, `sessionBreak` and `overtimeBreak` on the tick; reset points as above |
| Scheduled core | `WorkholicCore/ScheduledBreaks.swift` (new) | Pure functions: window test, due entry, remaining time |
| Plan model | `Workholic/BreakPlan.swift`, `ApiClient.swift` | New fields, Codable defaults, payload |
| Mac editor | `Workholic/BreakEditor.swift` | Tabbed: the existing layout moves unchanged into the first tab |
| Overlay | `Workholic/BreakOverlay.swift` | An optional "5 more minutes" button |
| Pause | `Workholic/PauseOverlay.swift` (new), `Workholic/PowerAssertion.swift` (new) | Cover and assertion |
| Wiring | `Workholic/AppModel.swift`, `main.swift` | The over-limit check, scheduled ticks, pause state, the covered gate, menu items |

## Testing

Unit tests come first (XCTest for Core, `node --test` for the worker):

- **Reminder:**
  - Every existing test passes unchanged. That is the evidence there is no regression.
  - A session break opens when the budget is reached, waits for a call, and is dropped by a rest-type sleep.
  - Overtime grows only while over the limit, opens at `every_minutes`, and resets when a break is taken.
  - Finishing any break clears `extraDue` and both stretches.
- **Scheduled:**
  - The window test at its edges.
  - Remaining time after a late wake.
  - Handled entries.
  - Snooze.
- **Gate:** `covered` blocks attention.
- **Worker:**
  - Parsing the new fields and their errors.
  - A partial PUT keeps the stored new fields.
  - The defaults validate.
- **The app:** `swift build` and `make build`. The overlays and the pause assertion need a manual check, using `pmset -g assertions` while paused.
