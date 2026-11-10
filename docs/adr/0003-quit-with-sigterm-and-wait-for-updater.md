# 0003. Quit with a signal and wait for the updater

Status: accepted 2026-11-09; corrected 2026-11-10 (SIGQUIT, not SIGTERM). The file keeps its
original name.

## Context

A switch has to close the running profile before opening the other. Cmd+Q, the tray's Quit and an
AppleScript `quit` all go through a guard that shows "Claude is still working" and blocks until
someone answers [C]. An automatic switch cannot wait on a dialog. With two instances of one bundle
id, AppleScript's target is also ambiguous.

The app installs its own handler for SIGINT, SIGTERM, SIGQUIT and SIGHUP: it sets the guard's
one-shot bypass and then runs the normal shutdown (stop sessions, flush stores), capped at about
75 s plus a 15 s watchdog [C].

Separately, a downloaded update is installed by Squirrel's `ShipIt` once the last instance of the
app has exited. Starting the app during that swap can launch a half-replaced bundle [C].

## What went wrong with SIGTERM

The first version sent SIGTERM, on the reading that the app's handler would run. On 2026-11-10 a
real switch stalled for 100 s and failed. The app's log showed why [V]:

- No "received signal" line for any SIGTERM quit. Chromium handles SIGTERM itself and starts an
  ordinary quit, so the app's handler, and its bypass, never run.
- That ordinary quit was "vetoed by before-quit interceptor": the dialog.
- The retry sent a second SIGTERM. Chromium resets its handler after the first, so the second one
  killed the app outright: the log has no cleanup lines for that exit.

On throwaway profiles, SIGQUIT is the one signal that logs "received signal … quitting now" and
then the full cleanup [V].

## Decision

1. Send **SIGQUIT** to the main pid of each instance that has to go. The main pid is the process
   whose executable is `Claude.app/Contents/MacOS/Claude`; its profile comes from its arguments.
2. Wait up to `quitTimeout` (100 s) for it to exit. If it does not, give up and change nothing,
   unless the caller passed `--force`, which sends SIGKILL. Never send a second quit signal to
   hurry it.
3. Wait up to 5 s for helper processes to release the data folder.
4. If no instance of the app is left and `ShipIt` is running, wait up to 120 s for it to finish,
   then for the app's executable to exist.

## Consequences

- A session that is mid-turn is stopped without the app's prompt. The menu bar app's own check (a
  transcript written in the last 20 s) is the only warning on a manual switch; an automatic switch
  does not ask.
- That SIGQUIT skips the dialog while a session is running is read from the code, not yet seen:
  the throwaway profiles had no session. Tracked in the plan.
- A switch across a pending update takes longer. It has happened once and completed [V]; how long
  it took was not recorded.
- If the app stops handling SIGQUIT, the default action kills it without cleanup. Re-check on app
  updates.
