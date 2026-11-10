# 0004. Detect limits with a Claude Code hook that only drops an event file

Status: accepted, 2026-11-09. Not yet proven against a real limit.

## Context

The switch should happen when a Code session stops on a usage limit. Signals available without
touching credentials:

| Signal | Notes |
| --- | --- |
| Claude Code `StopFailure` hook, matcher `rate_limit` | Supported hook. Fires for transient 429s too, so the payload has to be classified |
| The transcript's last API error | Carries `apiError: usage_limit_reached` and the reset time as an epoch [V on real transcripts] |
| `errorCategory: rate_limit` in the session record | Written by the app; would need polling |
| `plan-usage-history.json` | Utilisation samples every few minutes; too coarse to trigger on, useful as a cross-check |

A hook runs as a child of the app. If the hook itself quit the app, it would be killed part-way.

## Decision

- Add a `StopFailure` hook (matcher `rate_limit`). It treats the stop as a usage limit when the
  message matches the limit wording or the transcript's last API error says so, takes the reset
  time from the transcript, and writes one small JSON file into the tool's `events` folder. It
  does nothing for sessions that are not desktop sessions of a configured profile. It always
  exits 0.
- The menu bar app, owned by launchd, reads the folder every 3 s and applies the switching rules.
- Add an async `SessionStart` hook that records which account a profile is signed in to, for menu
  labels and the same-account check.
- The profile is identified from `CLAUDE_CODE_EXECPATH`, which lies under the profile's data
  folder.

## Consequences

- No switch happens while the menu bar app is not running. Accepted.
- Up to 3 s of delay. Accepted.
- The design depends on user-level hooks firing in desktop sessions. That is seen for an existing
  hook [V] but not yet for these two [Q]; first item in the plan.
- The real hook payload at a usage limit is inferred from documentation and the binary, not
  observed [Q].
