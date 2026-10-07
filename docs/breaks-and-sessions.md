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

The message and the countdown show for a few seconds, then fade almost to nothing. A clock counting down a 20-minute break is something to watch, which defeats the purpose. They come back for the last 3 minutes, and for a few seconds whenever you move the mouse or press a key, so Skip and "5 more minutes" are always easy to find.

## Settings are one copy, the latest save wins

Break settings and the daily limit live in the account. An edit on a Mac goes up at once. Every Mac, and the web Settings page while it is open, asks every 10 seconds whether anything changed. That check is one small request (`GET /v1/settings` returns the limit and when breaks last changed). The full break list is fetched only when that time moves.

If two places edit breaks before either has heard of the other, the later edit wins. A Mac compares the time of its own unsent edit with the account's `updated_at_ms`. The web form keeps unsaved edits and says another device changed breaks; saving then wins because it is later.

The readings themselves (attended time) still upload on the slower 5-minute sync. That is the only real syncing: settings are not merged, only replaced.

## Breaks are per Mac; the day is per account

Each Mac runs its own breaks and counts its own sessions. A break on one Mac does not stop you from using another device. That time is real and it counts: the server merges every device into one day (`worker/src/merge.ts`), so time on Mac B during Mac A's break goes toward today's total like any other. The Mac only stops counting itself while its own screen is covered.
