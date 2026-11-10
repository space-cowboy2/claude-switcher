# Claude Switcher: specification

| | |
| --- | --- |
| Version described | 0.1.0, as built and installed on 2026-11-09 |
| Scope of this document | What exists, what is proven, and what still has to change |
| Work breakdown | [plan.md](plan.md) (milestones and GitHub issues) |
| Decisions | [adr/](adr/) |

Every claim below carries one of five marks:

| Mark | Meaning |
| --- | --- |
| **[V]** | Verified: by a test in this repo, by a run against the real app, or by live use |
| **[C]** | Read from the app's shipped code (Claude desktop 4.23118.0), not exercised. The app is now 4.23118.1 and these have not been re-checked |
| **[D]** | A decision this project made |
| **[A]** | An assumption nobody has tested |
| **[Q]** | An open question |

## 1. Problem and users

One person has two Claude accounts and one Mac. When the account in use reaches its usage limit in
the Claude desktop app's Code tab, work stops until the limit resets. The app shows one account at
a time, and each account sees only its own Code sessions, so moving to the other account means
signing out, signing in, and losing the session you were in.

**User:** the owner of this repo, working alone on one Mac. There is no second user, no team use
and no server. **[D]**

## 2. Goals, scope and exclusions

### Goals

| # | Goal |
| --- | --- |
| G1 | Switch the desktop app between two signed-in accounts without signing in again |
| G2 | Show the same Code session list on both accounts |
| G3 | When a session stops on a usage limit, switch by itself and reopen that session on the other account |
| G4 | Make it obvious which account is active and how much usage each has left |
| G5 | Be removable, leaving Claude and its sessions as they were |

### In scope

Two profiles of the Claude desktop app on macOS; the Code tab's local sessions; a menu bar app; a
command-line tool; two Claude Code hooks; install and uninstall scripts; backups.

### Exclusions **[D]**

- Typing "continue" on the user's behalf after a switch.
- More than two accounts in the menu (the engine handles N profiles; the menu assumes two).
- Sharing anything that belongs to an account on Anthropic's side: connectors, scheduled tasks,
  Cowork sessions, Remote Control links, usage, billing.
- Sharing per-profile interface state: sidebar sections, pins, stars, unsent queued input.
- Patching or re-signing the Claude app. Reading or copying credentials of any kind.
- Windows, Linux, the claude.ai website, the standalone `claude` CLI's own login.

## 3. User journeys

### J1. First setup

1. Run `scripts/install.sh`. The ⇄ icon appears in the menu bar showing `1`.
2. Choose **Set up Account 2…**, then **Continue**.
3. Claude quits. Sessions are copied into the second profile. Claude reopens on that profile at
   its sign-in screen.
4. Sign in with the second account. The session list is there.

Expected: no further restart when the second account is one this Mac has seen before; one
automatic restart when it is new (its session folder did not exist to be filled). For a known account: the copy is **[V]** (live, 2026-11-09: 8 folders, 231 records copied); that
the second account then showed the list is inferred from the app writing its own index file into
the copied folder, and has not been confirmed by eye **[A]**. **[A]** for a new account (unit-tested rule, never run live).

| Edge case | Behaviour |
| --- | --- |
| A pending Claude update | The switcher waits for the updater to finish before reopening (up to 120 s) **[V]** live: the app came back as 4.23118.1 |
| User signs in to the same account on both profiles | Menu shows "Both profiles are signed in to the same account."; automatic switching refuses **[V]** unit |
| Claude does not quit within 100 s | Nothing is changed; a notification says so **[V]** unit |

### J2. Manual switch

Menu → **Switch to Account N**, ⌃⌥S, clicking the other account's row, or `claude-switch switch`.

Expected: Claude quits (SIGTERM), sessions sync, Claude opens on the other profile, signed in.
**[V]** live in both directions on the real profiles; about 1 s on empty throwaway profiles, the
real figure has not been timed **[Q]**.

| Edge case | Behaviour |
| --- | --- |
| A session wrote to its transcript in the last 20 s | The menu bar app asks "Claude looks busy" before switching **[V]** build only, not seen live |
| Target profile is already the one running | The app is brought to the front; nothing quits **[V]** unit |
| Sync fails | Logged; Claude is still started on the target with its list as it was **[V]** unit |
| Another switch is in progress | Refused with "Another switch is already in progress." **[V]** unit (lock) |

### J3. Automatic switch at a usage limit

1. A Code session's turn ends with an API error. Claude Code runs the `StopFailure` hook.
2. The hook decides whether it was a usage limit (not a transient 429) and, if so, drops an event
   file. It never fails or delays the session.
3. Within 3 s the menu bar app reads the event, records "this account is limited until its reset
   time", and applies the rules in FR-6.
4. If the rules pass: quit, sync, open the other profile with a link that reopens the same
   session. A notification says what happened. The user types "continue".

**[V]** on throwaway profiles with a real-shaped payload (3 s from event to the other profile being
up, session link passed). **[Q]** on the real profiles: no real usage limit has occurred since
install, and the real payload has never been captured. **[Q]** whether the hooks fire in real
desktop sessions at all: see section 12, risk R1.

| Edge case | Behaviour |
| --- | --- |
| Transient 429 or overload | Ignored **[V]** unit and integration |
| Several sessions fail at once | First event switches; the rest are dropped by the 90 s debounce **[V]** unit |
| Other account also limited | No switch; notification "Both accounts are at their limit. … resets …" **[V]** unit |
| Other profile never signed in | No switch; notification **[V]** integration |
| Reset time unknown | The account counts as limited for 60 minutes **[V]** unit |
| Event older than 3 minutes, or from a profile that is no longer the one running | Dropped **[V]** unit |
| Menu bar app not running | Events wait in the folder and go stale; nothing switches **[D]** |
| Limit hit in a terminal `claude` session | Ignored: that session uses the CLI's own login **[V]** unit |

### J4. Ordinary use around the switcher

| Situation | Behaviour |
| --- | --- |
| User quits Claude by hand | The menu bar app notices within 3 s and syncs, so either profile opens with a current list **[V]** build; **[A]** live |
| User opens Claude from the Dock | The default profile (Account 1) opens; macOS will not open a second copy by itself **[C]** |
| Claude updates itself | It restarts on Account 1 regardless of what was open **[C]** |
| Both profiles running at once | Not prevented. The menu shows a warning line. Last writer wins on shared records **[D]**, tracked in the plan |
| Session deleted on one account | Removed from the other at the next sync; a copy of the record is kept in `backups/deleted` **[V]** unit |

### J5. Undo

`scripts/uninstall.sh` removes the app, login item, CLI link and hooks. Sessions stay in every
folder they were copied to. The first sync's backup of each original folder stays under
`backups/initial-*`. **[V]** hooks removal unit-tested; the full script has not been run **[A]**.

## 4. Functional requirements

| # | Requirement | State |
| --- | --- | --- |
| FR-1 | Run each account as a separate app profile: Account 1 is the app's default data folder, Account 2 is started with `--user-data-dir=<folder>` | Built **[V]** |
| FR-2 | Identify running instances and their profile from the main process's arguments; ignore instances on folders that are not configured | Built **[V]** |
| FR-3 | Quit with SIGTERM to the main pid, wait for exit (default 100 s), then wait for helpers and for a pending update | Built **[V]** |
| FR-4 | Sync session records between every `<account>/<org>` folder of every profile, only while no configured profile runs | Built **[V]** |
| FR-5 | Sync rules: newest copy wins; deletions propagate unless the session changed elsewhere; a wiped folder or a deletion of more than half the list deletes nothing; first sync backs up every folder | Built **[V]** |
| FR-6 | Automatic switch only if all hold: auto is on; event under 3 min old; the limited profile is the only one running; no switch in the last 90 s; the other profile is signed in, to a different account, and not marked limited | Built **[V]** |
| FR-7 | Tell a usage limit from a transient error using the hook's message and the transcript's last API error; take the reset time from the transcript | Built **[V]** on real transcript samples; live payload **[Q]** |
| FR-8 | Reopen the limited session on the other profile through `claude://code/continue?session=local_<id>` | Built **[V]** argument passed; that the real app opens the session **[Q]** |
| FR-9 | Menu bar: active account, per-account label and last known usage, switch item with ⌃⌥S, auto toggle, Open Claude | Built **[V]** by printed menu model, not by eye |
| FR-10 | Install hooks into `~/.claude/settings.json` changing only the `hooks` value, with a backup; removable; idempotent | Built **[V]** |
| FR-11 | A session started on one account continues on the other | **[Q]** never tried; see plan |
| FR-12 | One command that checks the installation end to end | Not built; see plan |
| FR-13 | Restore sessions from the backups | Not built; see plan |

## 5. Nonfunctional requirements

| # | Requirement | State |
| --- | --- | --- |
| NFR-1 | Never read, copy or log credentials: no cookies, token caches, keychain items | Met by design **[V]** (code review; one non-secret key is read, section 9) |
| NFR-2 | Never write inside a profile except session record files and the folders that hold them | Met **[V]** |
| NFR-3 | No data loss from one mistake: backups before first sync, a kept copy of every propagated deletion, mass-delete refusal | Met **[V]** unit |
| NFR-4 | A hook returns in well under a second and always exits 0 | Met **[V]** (exits 0); timing not measured **[A]** |
| NFR-5 | Switch completes in 20 s or less on the real profiles, excluding update installs | **[Q]** not timed |
| NFR-6 | All logic testable without the real app | Met **[V]**: 41 tests against a fake process table and clock |
| NFR-7 | Survives app updates: the internals it relies on are listed and can be re-checked | Listed in section 8; no check exists yet, see plan |

## 6. Architecture

```
 Claude Code session (child of the app)          Menu bar app (LaunchAgent)
 ┌──────────────────────────────┐               ┌─────────────────────────────┐
 │ StopFailure / SessionStart   │  event file   │ every 3 s: read events,     │
 │ hook → `claude-switch hook`  ├──────────────►│ decide, switch, sync,       │
 └──────────────────────────────┘               │ redraw the menu             │
                                                └──────────────┬──────────────┘
 `claude-switch` CLI ──────────────────────────────────────────┤
                                                               ▼
                                              SwitchCore (library, all logic)
                                 ┌───────────┬───────────┬───────────┬──────────┐
                                 │ Engine    │ Session   │ Limit     │ Hook     │
                                 │ quit/wait │ Sync      │ classifier│ installer│
                                 │ /launch   │           │ + rules   │          │
                                 └───────────┴───────────┴───────────┴──────────┘
```

| Component | File | Role |
| --- | --- | --- |
| `SwitchCore` | `Sources/SwitchCore/` | Everything that decides or changes something. No UI. System access (process list, kill, open, clock) sits behind the `System` protocol so tests can replace it |
| `claude-switch` | `Sources/claude-switch/main.swift` | Thin CLI over `SwitchCore`; also the hook entry points |
| `ClaudeSwitcher` | `Sources/ClaudeSwitcher/main.swift` | AppKit status item; one serial work queue; notifications; global shortcut |

Why the hook does not switch by itself: it runs as a child of the app that the switch is about to
quit. It writes a file and exits; the menu bar app, which launchd owns, does the work. **[D]**
([ADR 0004](adr/0004-limit-detection-by-hook.md))

Switch sequence: lock → find running instances → SIGTERM those that are not the target → wait for
exit → wait for helpers to release the data folder → wait for the updater → sync → record the
switch → `open -n -a Claude --args [--user-data-dir=…] [claude://…]`.

## 7. Interfaces

### Command line

| Command | Effect |
| --- | --- |
| `claude-switch status` | Both profiles: running, signed in, label, usage, limit mark |
| `claude-switch switch [--to N] [--session local_ID] [--force]` | Switch. `--force` sends SIGKILL after the timeout instead of giving up |
| `claude-switch sync` | Sync now; refuses while Claude runs |
| `claude-switch auto on\|off` | Toggle automatic switching |
| `claude-switch menu` | Print what the menu bar shows |
| `claude-switch install-hooks` / `uninstall-hooks` `[--settings FILE] [--bin PATH]` | Edit the hooks |
| `claude-switch hook stop-failure\|session-start` | Called by Claude Code |
| `claude-switch test-limit --profile N [--session local_ID]` | Write a limit event as if profile N had hit its limit |
| `--home DIR` or `CLAUDE_SWITCH_HOME` | Use another state folder (experiments on throwaway profiles) |

### Hook contract

| Hook | Reads | Writes |
| --- | --- | --- |
| `StopFailure`, matcher `rate_limit`, timeout 20 s | stdin JSON: `error`, `last_assistant_message`, `transcript_path`. Environment: `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXECPATH`, `CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_HOST_SESSION_ID` | `events/limit-<ms>-<pid>.json`, only for a desktop session on a configured profile that stopped on a usage limit |
| `SessionStart`, no matcher, async, timeout 10 s | Environment: the above plus `CLAUDE_CODE_ORGANIZATION_UUID`, `CLAUDE_CODE_USER_EMAIL` | `events/identity-<profile>.json`, overwritten each time |

The profile a session belongs to is taken from `CLAUDE_CODE_EXECPATH`: each profile downloads its
own copy of Claude Code under its data folder. **[V]** both real profiles have their own copy.

## 8. What it relies on in the Claude desktop app

None of this is a documented interface. Each item can break in any app update.

| # | Reliance | Evidence |
| --- | --- | --- |
| I1 | `--user-data-dir` starts an independent profile; two instances can run side by side | **[V]** live |
| I2 | Sessions are `claude-code-sessions/<account>/<org>/local_<id>.json`; a record names no account, so a copy in another account's folder is that account's session | **[C]**; **[V]** in part: the second account loaded a copied folder and wrote its index into it |
| I3 | The app opens that folder with `O_NOFOLLOW`, so a symlinked folder cannot be saved to | **[C]**, behaviour reproduced outside the app |
| I4 | The list is loaded at start and on account change only; no file watching | **[C]** |
| I5 | SIGTERM to the main process quits cleanly and skips the "Claude is still working" dialog | **[C]**; **[V]** that it exits |
| I6 | The updater (Squirrel `ShipIt`) replaces the app bundle after the last instance exits | **[C]**; **[V]** once, live |
| I7 | `claude://code/continue?session=local_<id>` given as a launch argument opens that session | **[C]** |
| I8 | Transcripts live only in `~/.claude/projects`, shared by both profiles | **[C]**; **[V]** every session checked (32) resolved there |
| I9 | `plan-usage-history.json` holds five-hour and seven-day utilisation per organisation | **[V]** read live |
| I10 | `config.json` key `lastKnownAccountUuid` names the account last signed in | **[V]** read live |
| I11 | Claude Code runs user-level hooks in desktop sessions and passes the environment in section 7 | **[V]** for an existing `SessionStart` hook with matcher `startup`; **[Q]** for the two hooks this tool adds |

Also true and worth knowing **[C]**: the second profile cannot pair with Claude in Chrome; it
keeps its own copy of Claude Code (about 300 MB); the app has its own "auto-continue when the limit
resets" engine per profile; the app contains an account switcher behind a server-side flag.

## 9. Data

All of the tool's own files are in `~/Library/Application Support/AccountSwitcher/`.

| File | Shape | Notes |
| --- | --- | --- |
| `config.json` | `appPath`, `profiles[{id, name, dataDir}]`, `autoSwitch`, `hotkey`, `quitTimeout` (100), `debounce` (90), `limitFallbackMinutes` (60), `defaultDataDir` | Hand-editable. A file that does not parse is left alone and defaults are used for that run |
| `state.json` | `manifest{folder: {ids[], syncedAt}}`, `limits{profile: {until, kind, at}}`, `identities{profile: {account, org, email, at}}`, `lastSwitch{at, from, to, reason}`, `setupProfile`, `initialBackupDone` | Written under a file lock. Mode 0600 |
| `events/limit-*.json` | `at`, `profileId`, `account?`, `sessionId?`, `resetsAt?`, `limitType?`, `message?` (first 200 characters of the error text) | Deleted when read |
| `events/identity-<n>.json` | `at`, `profileId`, `account`, `org?`, `email?` | One per profile, overwritten |
| `backups/initial-<epoch>/folder-<n>/` | Copies of every record as it was before the first sync, plus `ORIGIN.txt` naming the source folder | Written once |
| `backups/deleted/` | The last copy of each session whose deletion was propagated | Never pruned **[Q]** |
| `switch.log` | One line per switch, sync, notification and skipped limit | Truncated at 1 MB |
| `profile-2/` | The second account's app data folder | Owned by the Claude app; holds that account's sign-in |

In each profile the tool writes only `claude-code-sessions/<account>/<org>/local_*.json` and
`deleted_*` marker files, and creates those folders when missing (mode 0700, files 0600).

The sync manifest is what makes deletion detectable: a session a folder held at the last sync and
no longer holds was deleted there. ([ADR 0002](adr/0002-copy-sessions-instead-of-linking.md))

## 10. Dependencies

| Dependency | Used for |
| --- | --- |
| macOS 13 or later; Xcode with Swift 5.9 or later | Build and run |
| Claude desktop app at `/Applications/Claude.app` | The thing being switched |
| Claude Code hooks (`StopFailure` exists from 2.1.78 **[A]**; present in 2.1.317 **[V]**) | Limit detection |
| `/bin/ps`, `/usr/bin/open`, `launchctl`, `codesign` (ad-hoc) | Process list, launch, login item, notifications |

No third-party packages. No network access of its own.

## 11. Security, privacy, permissions and operations

**Credentials.** The tool never opens cookie stores, token caches or the keychain. From each
profile's `config.json`, which also holds an encrypted token cache, it reads the single key
`lastKnownAccountUuid` and discards the rest. **[V]** by reading the code.

**Personal data it stores**, locally and only in `state.json` and event files: account id,
organisation id, the account's email address, and up to 200 characters of a limit error message.
Nothing leaves the machine. Logs hold no conversation text. **[V]**

**Trust boundary.** Any process running as the user can drop a file into `events/` and cause a
switch. That is the same boundary as being able to quit the app; accepted. **[D]**

**macOS permissions.** Notifications (asked once). No Accessibility, Automation, Full Disk Access
or Screen Recording. The global shortcut uses Carbon hot keys, which need none. **[V]**

**Signing.** Ad-hoc. Good for the machine it was built on; not distributable. **[D]**

**Terms of service.** Whether running a second account to keep working past a usage limit is
permitted by Anthropic's terms is **not established**. **[Q]**, owner's decision, tracked in the
plan. The repository is private until that is settled. **[D]**

**Operations.**

| Task | How |
| --- | --- |
| See what happened | `switch.log` |
| Check state | `claude-switch status`, `claude-switch menu` |
| Stop automatic switching | Menu toggle or `claude-switch auto off` |
| Stop everything | Menu → Quit Switcher (stays quit until next login) |
| Recover a session record | Copy it from `backups/deleted` or `backups/initial-*` into a session folder while Claude is closed |
| After a Claude update | Nothing automatic yet; see plan |

## 12. Risks and open questions

| # | Item | Mark | Consequence if it goes wrong |
| --- | --- | --- | --- |
| R1 | Do the two hooks fire in real desktop sessions? After a real app restart, the resumed session produced no identity event, and none has ever arrived from Account 2 | **[Q]** | Automatic switching silently never happens |
| R2 | Real `StopFailure` payload at a usage limit has never been seen | **[Q]** | A real limit could be classified as transient, or lack the reset time |
| R3 | A session started on one account has never been continued on the other | **[Q]** | G3 fails at the last step |
| R4 | Deleting a session on Account 1 deletes its transcript although Account 2 still lists it: the default profile does not know about the second profile's records | **[C]** | A dead entry on Account 2 until the next sync removes it |
| R5 | The app's own limit auto-resume may send a stale "continue" after switching back | **[C]** | A surprising message in a session |
| R6 | Both profiles open at once | **[D]** not prevented | Silent last-writer-wins on session metadata |
| R7 | Session copies also land in two account/org folders that are artefacts of past sign-ins (8 folders for 2 accounts) | **[V]** | Wasted space (about 7 MB each); possible effect on the app's import prompts **[A]** |
| R8 | Any reliance in section 8 changes in an app update | **[A]** | Anything from a stale list to a failed switch |
| R9 | Anthropic turns on the built-in account switcher | **[C]** | The tool becomes unnecessary; plan a clean exit |
| R10 | Terms of service | **[Q]** | Account risk |

### Where each open item is tracked

| Spec item | Issue |
| --- | --- |
| R1, A10, I11: hooks in real sessions | [#1](https://github.com/space-cowboy2/claude-switcher/issues/1) |
| R2, A12: real limit payload | [#7](https://github.com/space-cowboy2/claude-switcher/issues/7) |
| R3, A11, FR-8, FR-11: drill and continue on the other account | [#2](https://github.com/space-cowboy2/claude-switcher/issues/2), [#3](https://github.com/space-cowboy2/claude-switcher/issues/3) |
| R4: delete strands a session | [#12](https://github.com/space-cowboy2/claude-switcher/issues/12) |
| R5: the app's own auto-resume | [#9](https://github.com/space-cowboy2/claude-switcher/issues/9) |
| R6: both profiles open | [#14](https://github.com/space-cowboy2/claude-switcher/issues/14) |
| R7: extra replica folders | [#16](https://github.com/space-cowboy2/claude-switcher/issues/16) |
| R8, A13, NFR-7: app updates | [#5](https://github.com/space-cowboy2/claude-switcher/issues/5), [#18](https://github.com/space-cowboy2/claude-switcher/issues/18) |
| R9: built-in switcher | [#19](https://github.com/space-cowboy2/claude-switcher/issues/19) |
| R10: terms of service | [#4](https://github.com/space-cowboy2/claude-switcher/issues/4) |
| FR-12 doctor, FR-13 restore | [#6](https://github.com/space-cowboy2/claude-switcher/issues/6), [#13](https://github.com/space-cowboy2/claude-switcher/issues/13) |
| Limit rules beyond FR-6 | [#8](https://github.com/space-cowboy2/claude-switcher/issues/8), [#10](https://github.com/space-cowboy2/claude-switcher/issues/10), [#11](https://github.com/space-cowboy2/claude-switcher/issues/11) |
| Upkeep | [#17](https://github.com/space-cowboy2/claude-switcher/issues/17), [#20](https://github.com/space-cowboy2/claude-switcher/issues/20) |

## 13. Acceptance criteria and testing

| # | Criterion | Evidence | State |
| --- | --- | --- | --- |
| A1 | Sync: both directions, deletes, idempotent, ignores symlinks and temp files, survives a wiped or removed folder, refuses mass deletion | 11 unit tests | Met |
| A2 | Limit classifier: real messages and transcript entries are limits with a reset time; transient errors are not | 6 unit tests | Met |
| A3 | Decision rules of FR-6, one test per reason | 2 unit tests (12 cases) | Met |
| A4 | Switch order, arguments, timeout, force, restart, updater wait, failed sync | 13 unit tests | Met |
| A5 | Hook install: idempotent, keeps other hooks, changes only the `hooks` value, leaves bad files alone | 4 unit tests and the real file | Met |
| A6 | Real app: switch between two throwaway profiles while the main app stays up | Integration run, 2026-11-09 | Met |
| A7 | Hook binary and menu bar app act on a real-shaped limit; ignore a transient one | Integration run, 2026-11-09 | Met |
| A8 | Menu bar app runs under launchd and shows the active account | Process and printed menu | Met; login persistence not observed |
| A9 | Second account signs in on the real profile and sees the shared list | Live: signed in; 33 records in all 8 folders; the app wrote its index in the copied folder | Sign-in and copy met; "sees the list" inferred, owner to confirm |
| A10 | Hooks fire in real desktop sessions on both profiles | none | **Open** (R1) |
| A11 | A simulated limit on the real profiles switches and reopens the session; a message sent there gets a reply | none | **Open** (R3) |
| A12 | A real usage limit switches | none | **Open** (R2); cannot be scheduled |
| A13 | The reliances in section 8 are confirmed on the current app version | none | **Open** |

Testing layers: unit tests (`swift test`, no real app); integration runs on throwaway profiles with
`--home` (real app, no real account, the main app untouched); live checks by the owner. Changes to
`SwitchCore` need the first; changes to quit, launch or hook handling need the second.

## 14. Rollout and success

Rollout is already done for the only user: installed 2026-11-09, both accounts signed in. From here
each milestone in [plan.md](plan.md) ships by `scripts/install.sh` on the same machine, and can be
backed out with `git checkout` of the previous tag and a reinstall.

| Measure | Target | How measured |
| --- | --- | --- |
| Time from a limit to working on the other account | Under 60 s | `switch.log` timestamps and the first transcript entry after |
| Automatic switches that succeed on real limits | 9 of the first 10 | `switch.log` |
| Switches caused by transient errors | 0 | `switch.log` against transcripts |
| Sessions lost or duplicated by sync | 0 | Record count equal in every folder; `backups/deleted` matches deliberate deletions |
| Manual recoveries needed after a Claude update | 0 | Owner's notes on issues |
