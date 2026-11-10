# Changelog

## 0.2.1 (2026-11-10)

- **Fix: a switch could stall for 100 seconds and then fail.** Claude's "still working" dialog
  blocked the quit, because SIGTERM never reaches the app's own signal handler. The quit signal is
  now SIGQUIT, which does. A retried SIGTERM also killed the app without its cleanup; that cannot
  happen now.
- **A manual switch lands on the session you had open**, not on the Code home screen. The link is
  passed at launch and sent again 8 seconds later (`reopenDelay`).
- Docs: the spec and decision record 0003 are corrected; stars and pins being per profile is
  recorded as a known gap.

## 0.2.0 (2026-11-10)

- **Renamed from Claude Switcher to Second Wind.** The repository is `second-wind`, the command is
  `secondwind`, the app is `Second Wind.app`, and the state-folder override is `SECONDWIND_HOME`.
  No behaviour changes. The state folder (`AccountSwitcher`) keeps its name, so nothing moves.
- The bundle identifier and login-item label are now neutral
  (`io.github.space-cowboy2.secondwind`). `scripts/install.sh` replaces an install made under the
  old name: old app, old command, old login item and old hooks.
- MIT license.
- App icon: two gusts of wind on a sunset plate, drawn by `scripts/make-icon.swift`.
- README: restructured as problem, solution, how it works, status, install, usage, limitations,
  with a real screenshot of the menu. Corrects the install note: only the `hooks` section of the
  settings file changes.
- Docs: full specification with evidence marks, decision records, contributing guide, and a
  milestone plan backed by GitHub issues.

## 0.1.0 (2026-11-09)

Released as Claude Switcher; the command was `claude-switch`.

- Two app profiles, one per account; switch from the menu bar, ⌃⌥S, or `claude-switch switch`.
- One Code session list across accounts and profiles (copied while Claude is closed).
- Automatic switch on a usage limit via a Claude Code `StopFailure` hook; the session reopens on
  the other account.
- Install and uninstall scripts; backups of every session folder before the first sync.
