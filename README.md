# Claude Switcher

Menu bar tool for one person with two Claude accounts on one Mac. It keeps each account signed in
as its own profile of the Claude desktop app, keeps one Code session list across both, and switches
profiles on a click, on ⌃⌥S, or by itself when the active account hits its usage limit.

## Documentation

| Document | What it covers |
| --- | --- |
| [docs/spec.md](docs/spec.md) | What the tool does, what is proven and what is not, requirements, architecture, data, risks |
| [docs/plan.md](docs/plan.md) | Milestones and the GitHub issues behind them |
| [docs/adr/](docs/adr/README.md) | Why it is built this way |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Rules for changing it |
| [CHANGELOG.md](CHANGELOG.md) | What changed |

## Install

```bash
scripts/install.sh
```

Needs Xcode (Swift 5.9+). Installs `~/Applications/Claude Switcher.app` (starts at login),
`~/.local/bin/claude-switch`, and two hooks in `~/.claude/settings.json` (a backup is written next
to it; keys are re-sorted alphabetically).

## First use

1. Click the ⇄ icon, choose **Set up Account 2…**, then **Continue**.
2. Claude quits and reopens on a fresh profile. Sign in with the second account.
3. Your sessions are already there. If you signed in to an account this Mac has not seen before,
   Claude restarts once more to load them.

## Day to day

| You want | Do |
| --- | --- |
| Switch accounts | Menu → **Switch to Account N**, or ⌃⌥S |
| Stop automatic switching | Menu → untick **Switch automatically at limit** |
| See what it did | `~/Library/Application Support/AccountSwitcher/switch.log` |
| Switch from a terminal | `claude-switch switch` |
| Check state | `claude-switch status` |

After an automatic switch the session that hit the limit is open on the other account. Type
"continue".

## What is and is not shared

Shared: the Code session list and every transcript, plus everything in `~/.claude` (settings,
memory, skills, plugins).

Per account: connectors, scheduled tasks, Cowork sessions, sidebar sections and pins, Remote
Control links, usage and billing.

Things to know:

- Switching quits Claude. A session that is mid-turn stops; it stays in the list.
- Sessions sync while Claude is closed: at every switch, and whenever the menu bar app sees Claude
  quit. Never run both profiles at once; the app does not prevent it and the last writer wins.
- A "No folder" session opened on the other profile behaves like a normal folder session and may
  ask to trust its folder.
- Remote Control on your phone follows the account, so a switch drops the phone's connection.
- The second profile cannot pair with Claude in Chrome and downloads its own copy of Claude Code
  (about 300 MB) the first time.
- An app update restarts Claude on Account 1, whatever was open.
- Deleting a session on one account removes it from the other at the next sync. A copy of the
  record is kept in `AccountSwitcher/backups/deleted`. The transcript is left in `~/.claude`.

## Undo

```bash
scripts/uninstall.sh
```

Sessions stay in both profiles. The first sync saved every session folder as it was under
`~/Library/Application Support/AccountSwitcher/backups/initial-*` (each folder has an `ORIGIN.txt`
naming where it came from).

## Develop

```bash
swift test
```

`SwitchCore` holds all logic (sync, switch engine, limit rules, hook installer, menu model) and is
tested without the real app. `claude-switch --home DIR …` points the tool at a throwaway config for
experiments with throwaway profiles.
