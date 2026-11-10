# 0003. Quit with SIGTERM and wait for the updater

Status: accepted, 2026-11-09

## Context

A switch has to close the running profile before opening the other. Cmd+Q, the tray's Quit and an
AppleScript `quit` all go through a guard that shows "Claude is still working" and blocks until
someone answers [C]. An automatic switch cannot wait on a dialog. With two instances of one bundle
id, AppleScript's target is also ambiguous.

The app handles SIGTERM itself: it sets the guard's bypass flag and then runs its normal shutdown
(stop sessions, flush stores), capped at about 75 s plus a 15 s watchdog [C].

Separately, a downloaded update is installed by Squirrel's `ShipIt` once the last instance of the
app has exited. Starting the app during that swap can launch a half-replaced bundle [C].

## Decision

1. Send SIGTERM to the main pid of each instance that has to go. The main pid is the process whose
   executable is `Claude.app/Contents/MacOS/Claude`; its profile comes from its arguments.
2. Wait up to `quitTimeout` (100 s) for it to exit. If it does not, give up and change nothing,
   unless the caller passed `--force`, which sends SIGKILL.
3. Wait up to 5 s for helper processes to release the data folder.
4. If no instance of the app is left and `ShipIt` is running, wait up to 120 s for it to finish,
   then for the app's executable to exist.

## Consequences

- A session that is mid-turn is stopped without a prompt. The menu bar app therefore asks first on
  a manual switch when a transcript was written in the last 20 s; an automatic switch does not ask.
- A switch across a pending update takes longer. It has happened once and completed [V]; how long
  it took was not recorded.
- If the app stops handling SIGTERM this way, a quit could skip the app's cleanup or be blocked.
  Re-check on app updates.
