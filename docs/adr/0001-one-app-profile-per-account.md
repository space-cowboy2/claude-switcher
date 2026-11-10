# 0001. One app profile per account

Status: accepted, 2026-11-09

## Context

The Claude desktop app shows one signed-in account. Switching means signing out and in through the
browser. The app's extension API (mods) cannot change the signed-in account [V]. The app does
contain an account switcher, but it is behind a server-side flag that is off for this user [C].

## Options

| Option | Why not |
| --- | --- |
| Sign out and in each time | A browser login per switch; cannot be automated without handling credentials |
| Swap the sign-in files of one profile | Means copying cookies and token caches; refresh-token rotation could sign the other copy out |
| Patch the app to add a switcher | Breaks the code signature; undone by every update |
| **A second profile started with `--user-data-dir`** | Chosen |

## Decision

Account 1 uses the app's default data folder. Account 2 uses
`~/Library/Application Support/AccountSwitcher/profile-2`, started with
`open -n -a Claude --args --user-data-dir=<folder>`. Each profile keeps its own sign-in. Only one
runs at a time; switching is quit one, start the other.

## Consequences

- No credential is ever touched by this tool. [V]
- Everything outside `~/.claude` is per profile: sidebar layout, connectors, Remote Control, the
  Claude Code binary (about 300 MB a copy), Claude in Chrome pairing (unavailable on profile 2). [C]
- App updates and launch-at-login always bring up Account 1. [C]
- Nothing stops both profiles running at once; the tool has to watch for it.
- If the built-in switcher is turned on, this whole approach should be retired.
