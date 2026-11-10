# Changelog

## Unreleased

- Docs: full specification with evidence marks, decision records, contributing guide, and a
  milestone plan backed by GitHub issues.

## 0.1.0 (2026-11-09)

- Two app profiles, one per account; switch from the menu bar, ⌃⌥S, or `claude-switch switch`.
- One Code session list across accounts and profiles (copied while Claude is closed).
- Automatic switch on a usage limit via a Claude Code `StopFailure` hook; the session reopens on
  the other account.
- Install and uninstall scripts; backups of every session folder before the first sync.
