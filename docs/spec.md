# Claude Switcher: spec

Status: approved direction (menu bar switcher, automatic at limit, shared sessions). 2026-11-09.

## What it is for

One person, two Claude accounts, one Mac. When the active account runs out of usage, carry on in
the same Code session on the other account with as little friction as possible.

## User experience

- A menu bar icon shows which account is active (`⇄ 1` or `⇄ 2`).
- The menu lists both accounts with the last known usage, a "Switch to account N" item (⌃⌥S),
  a "Switch automatically at limit" toggle, and "Open Claude".
- Switching quits Claude and reopens it on the other account's profile, already signed in, with
  the same session list. About 15 seconds.
- When a Code session fails with a usage limit and the toggle is on, the switch happens by itself
  and the session that hit the limit is reopened on the other account. You type "continue".
- First use: pick "Set up Account 2…", sign in once in the window that opens. Nothing else.

## How it works (decisions and the findings behind them)

| Decision | Finding that forced it |
| --- | --- |
| Each account is a separate app profile (`--user-data-dir`) | The app has no account switcher; the built-in multi-account feature is behind a server flag. A second profile runs fine (tested). |
| Sessions are **copied** between account folders while Claude is closed | The app opens its session folder with `O_NOFOLLOW`, so a symlinked folder lists sessions but every save fails. Records carry no account id, so a copy is a first-class session. Transcripts already live in `~/.claude` and are shared. |
| Every `<account>/<org>` folder in every profile holds the full list | No guessing which folder a profile will use after sign-in. |
| Quit with `SIGTERM` to the main pid | It skips the "Claude is still working" dialog but still runs the app's clean shutdown. Cmd+Q and AppleScript can be blocked by that dialog. |
| Wait for the updater before relaunching | A staged update swaps the app bundle when the last instance exits. |
| Limit detection is a Claude Code `StopFailure` hook (matcher `rate_limit`) | Supported hook; the payload and the transcript tell a real usage limit (with reset time) from a transient 429. |
| The hook only drops an event file; the menu bar app does the switch | The hook is a child of the app that is about to quit. |
| Reopen the session with `claude://code/continue?session=local_…` | The app handles that link on cold start. |

## Scope

In: two profiles, shared Code session list, manual switch, automatic switch at a usage limit,
menu bar status with usage, install and uninstall, backups.

Out (not shared between accounts): sidebar sections and pins, connectors, scheduled tasks, Cowork
sessions, Remote Control links, git worktree ownership, unsent queued input. Also out: typing
"continue" for you, more than two accounts in the menu, patching the app.

## Requirements

1. Never touch credentials. No cookies, tokens or keychain. The only app file read for identity is
   `lastKnownAccountUuid` in a profile's `config.json`.
2. Never sync while a configured profile is running; never start a profile that is already running.
3. Sync is safe to repeat, propagates deletions, and cannot mass-delete: a wiped folder or a
   deletion of more than half the list is ignored. First sync backs up every folder; every
   propagated deletion keeps a copy.
4. A limit event switches only if: auto is on, the event is fresh, the limited profile is the one
   running, the other profile is signed in to a different account and is not itself marked
   limited, and no switch happened in the last 90 seconds.
5. Transient 429 / overload errors never switch.
6. Everything is reversible: `uninstall.sh` removes the hooks, login item and app; sessions stay
   where they are; backups are kept.

## Acceptance criteria

| # | Criterion | How it is checked |
| --- | --- | --- |
| A1 | Sync copies new and newer records both ways, propagates deletes, is idempotent, ignores symlinks, survives a wiped folder | unit tests |
| A2 | Limit classifier: real limit text and transcript → limit with reset time; transient 429 → ignored | unit tests |
| A3 | Decision rules in requirement 4 | unit tests |
| A4 | Switch order: quit → wait → updater wait → sync → launch with the right arguments; abort on quit timeout | unit tests with a fake system |
| A5 | Hook install is idempotent and keeps existing hooks | unit tests + the real settings file |
| A6 | Real app: switch between two throwaway profiles while the main app keeps running untouched | integration run |
| A7 | Hook binary turns a real-shaped `StopFailure` payload into an event; the menu bar app acts on it | integration run on throwaway profiles |
| A8 | Menu bar app runs, shows the active account, survives login | run + `claude-switch menu` |
| A9 | Second account signs in and sees the shared list; a real limit triggers the switch | **needs the owner**: sign-in and a real limit cannot be done by the builder |

## Plan

1. Core library (`SwitchCore`): model and store, session sync, process detection, switch engine,
   limit classifier, hook installer, usage reader, menu model.
2. `claude-switch` CLI: `status`, `switch`, `sync`, `auto`, `menu`, `hook …`, `install-hooks`.
3. `ClaudeSwitcher` menu bar app.
4. Tests, then `scripts/install.sh` (build, app bundle, login item, hooks).
5. Integration runs on throwaway profiles; install; verify A1 to A8.
