# Breaks and sessions

Why Workholic has no "start a session" button, and what a break is for.

## A session is not something you start

A session is the time you spend looking at a screen between breaks. It starts when you sit down and start using a device. It ends when you step away. Nobody decides to "start a 25-minute session". Work just happens, and that stretch is the session.

Earlier versions had "Start a 25 min session", "Start a 50 min session" and an "After a session" break. They were removed. A session you have to remember to start measures nothing on the days you forget, and the every-few-minutes break already covers the same idea without the bookkeeping.

## A break is the prompt to step away

Breaks are how a session ends when you would not end it yourself. The Mac counts attended time since the last break. When it reaches the interval you chose, the screen goes dark until the break is over. Every kind of break does that one job:

| Break | When it comes |
|---|---|
| Every few minutes | After N minutes of looking since the last break |
| Past the limit | Once today's limit is reached, after every N minutes past it. It replaces the every-few-minutes break, so sessions get shorter |
| At set times | At a clock time, such as lunch |
| By hand | Whenever you start one from the menu bar |

Stepping away for 5 minutes, turning the screen off, or sleeping the Mac also ends the session. The next break is then a full interval away.

## What the break screen looks like

The screen stays black and stays on. The display is kept from sleeping for the length of the break. A dark screen asks you to step away; a sleeping one looks like nothing happened.

The message and the countdown show for a few seconds. Then the countdown and the buttons fade almost to nothing: a clock counting down a 20-minute break is something to watch, which defeats the purpose. The message dims but stays readable, so a dark screen always says it is a break and not a dimmed screen to keep working on. Everything comes back for the last 3 minutes, and for a few seconds whenever you move the mouse or press a key, so Skip and "5 more minutes" are always easy to find.

A black window still leaves the panel lit, so the backlight goes down too while the countdown is faded, and comes back with it. This uses DisplayServices, the private framework behind the brightness keys. It reaches built-in and Apple displays; other monitors only get the black cover. The level before dimming is saved, so a crash mid-break is undone at the next launch. The backlight only goes down while the cover is actually on the screen, so a dim screen without the cover cannot happen. Moving the mouse, clicking, scrolling, or pressing a key brings it back up at once, even when another app has the focus, and it goes down again after a few quiet seconds. The Pause screen does the same. When a break ends, however it ends, the cover goes away and the screen returns to the brightness it had before.

External monitors are handled as they come and go. One plugged in while the screen is dimmed gets the cover and the dim too. One unplugged (or a laptop lid closed) while dimmed gets its brightness back when it returns, instead of staying dark. One that wakes from sleep at its own brightness is turned down again. Each cover window's frame is set to its display's frame after the window is made, because the window initializer reads the frame relative to the display's corner, which can push a second display's cover off that display. Plugging a monitor in sends several notices and the screen list can lag behind them, so the Pause screen checks itself every two seconds and on any input; the break screen checks every second.

Whether a cover is really showing is asked of the window server (is each cover window on screen now), not of `isOnActiveSpace`, which with a second monitor can call a cover present that sits on a desktop no display is showing. The window server lists a window only a run loop turn after it is ordered front, so a cover just put up gets a moment before it can be judged missing. The screen dims only while every display shows the cover; a missing cover brightens the screen and is rebuilt where the user is. A dark screen with no cover on it was the old failure.

Input is noticed two ways: event monitors, which are instant, and a check once a second of when the keyboard or mouse was last touched (`CGEventSource.secondsSinceLastEventType`, no permission needed). The monitors alone missed mouse moves: an active app gets none unless its key window asks for them, and the Pause screen's windows did not ask, so moving the mouse could not brighten a dimmed Pause screen.

Unpausing a locked pause asks for the Mac password. Clicking Unpause again while a prompt is open closes that prompt and opens a new one, since a prompt still open but not seen is likely on another display. Putting the cover back while the prompt is up no longer takes the focus from the prompt.

While a break is up, app switching, the Dock, and Hide are blocked; Esc still skips. The cover puts itself back if a display is plugged in or out, the Space changes, or anything takes it down. Windows set to join every Space can still stay behind on the desktop they opened on, so on every desktop switch (and, as a fallback, on the next mouse move or countdown second) a cover that is not on the desktop now showing is rebuilt there. This holds for the Pause screen too. With the dashboard window open, Workholic is a Dock app, and a Dock app's windows cannot cover another app's full-screen Space. So while a break or pause cover is up, Workholic steps back to a menu bar app, and the Dock icon returns after.

## Pause, and locking it

Pause is for stepping away while something keeps working, such as an agent. The Mac stays awake, programs keep running, nothing is counted, and the screen is black with the backlight down.

"Lock the Pause screen with this Mac's password" (This Mac, in Settings) makes Unpause and "Unpause for 5 minutes" ask for the Mac password or Touch ID first. While the locked cover is up, app switching, Force Quit, Hide, Quit, and logging out are blocked.

It is not the macOS lock screen. That screen cannot show Workholic's cover, and it brings the display's own sleep timers with it. The price is that this lock only guards the keyboard. Someone who can end the app another way, such as over SSH, gets past it. Holding the power button still restarts the Mac if anything ever goes wrong.

## Shutting a Mac down from the web

Settings › Devices has "Shut down…" beside each Mac. It is for a Mac left on and paused, such as one running an agent, that should not stay on. The order waits on the server until that Mac picks it up: within about a minute if Workholic is running there and nobody is at it, within five minutes if someone is (opening the menu bar menu checks at once), otherwise the next time it runs while signed in. Cancel withdraws it until then.

- Only a login session (the web app, or a Mac's dashboard window) can ask for or cancel a shutdown. A Mac's device token cannot, so a token taken from one Mac cannot shut down another.
- A Mac reads only its own orders, with its device token (`GET /v1/devices/{id}/commands`).
- The Mac acknowledges an order before acting on it (`POST /v1/devices/{id}/commands/{command}:ack`). The server says go only to the first acknowledgement of an order nobody cancelled, so a restart cannot shut it down twice and a cancel that wins the race stops it.
- To shut down, Workholic lifts its covers and the locked pause's kiosk mode, which would otherwise block it, and sends loginwindow the "shut down" Apple Event: the Apple menu's Shut Down without the dialog. Apps are asked to quit, so one with unsaved work can still stop it. If macOS refuses the request, the Mac reports it and the web shows that the shutdown did not go through.
- Settings › Devices also shows when each Mac last checked in ("on now" within the last 7 minutes), from those checks.

## Scheduled shutdown

Each Mac can shut itself down daily. It is set per device in Settings › Devices, where each Mac shows a one-line summary ("Daily shutdown: 30m after today's limit, or later if last-meeting-end says so") that opens into the form. It is stored in the account and reaches the Mac with its order check (`GET /v1/devices/{id}/commands` returns `shutdown_schedule`). The Mac keeps the last one it heard, so it holds offline; logging out clears it. Setting it takes a login session (`PUT /v1/devices/{id}/shutdown-schedule`), like a shutdown.

```json
{ "when": "limit", "after": null, "delay_minutes": 30, "command": "last-meeting-end" }
```

The shutdown comes due one of two ways:

- `when: "time"`: after `after`, the Mac's own local `HH:MM`.
- `when: "limit"`: `delay_minutes` (0–720, by the clock) after today's limit is crossed. The crossing counts only if Workholic saw the total under the limit earlier that day, so a Mac started already over does not shut down.

`command` (optional) is for days that run late, such as a meeting after the usual time: the Mac also waits for the time the script prints. Whichever is later wins; a script can push the shutdown later, never earlier.

`command` is only a script's file name. The Mac runs it from `~/Library/Application Support/tech.joeljacob.workholic/commands/`, through `zsh -l` so PATH matches Terminal's, with a 30-second limit. The script lives only on that Mac, with whatever credentials it needs (a calendar, say). The account can pick among scripts already there but cannot send the Mac code. The script prints when shutting down is fine, such as when the last call accepted for today ends, as either:

- `HH:MM`, on today's date in this Mac's time zone, or
- ISO 8601 with a zone: `2026-10-17T21:30:00-07:00` or `2026-10-18T04:30:00Z`.

The script runs only once the time and limit parts hold, then again every 5 minutes until its time passes. A time that has passed is acted on only from a run in the last minute.

It is built so that it never shuts down by surprise:

- Anything unclear means no shutdown: a schedule that fails the Mac's own checks, a script that is missing, not executable, fails, times out, or prints anything but a time, or a limit or today's total not known yet. The menu says why.
- It fires only when Workholic saw it "not yet due" earlier the same day. Starting the Mac after the time does not shut it down. (A Mac that slept through the time does get the warning when it wakes.)
- A call (microphone or camera in use) holds it until the call ends.
- A 60-second window over everything, the break and pause covers included, counts down with Cancel (Return or Esc) and Shut Down Now. A call that starts during the countdown also stops it.
- Once warned, the day is done. A cancel, or an app that refuses to quit, is not tried again until tomorrow.

The shutdown itself is the same as one from the web: covers lifted, then the "shut down" Apple Event.

## Settings are one copy, the latest save wins

Break settings and the daily limit live in the account. An edit on a Mac goes up at once. The web Settings page, while it is open, asks every minute whether anything changed (`GET /v1/settings` returns the limit and when breaks last changed). A Mac gets the same fields in its order check (`GET /v1/devices/{id}/commands` returns `settings`), so each check is one request: every minute when nobody is at the Mac, every five minutes while someone is, and at once (at most every 15 seconds) when the menu bar menu or a window opens or the Mac wakes. The full break list is fetched only when that time moves. A break edit goes up at once.

If two places edit breaks before either has heard of the other, the later edit wins. A Mac compares the time of its own unsent edit with the account's `updated_at_ms`. The web form keeps unsaved edits and says another device changed breaks; saving then wins because it is later.

The readings themselves (attended time) still upload on the slower 5-minute sync. That is the only real syncing: settings are not merged, only replaced.

## Breaks are per Mac; the day is per account

Each Mac runs its own breaks and counts its own sessions. A break on one Mac does not stop you from using another device. That time is real and it counts: the server merges every device into one day (`worker/src/merge.ts`), so time on Mac B during Mac A's break goes toward today's total like any other. The Mac only stops counting itself while its own screen is covered.
