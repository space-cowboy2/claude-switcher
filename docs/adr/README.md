# Decision records

One file per decision that shaped the design. Each says what was decided, why, and what it costs.
The evidence marks ([V], [C], [A]) are defined in [../spec.md](../spec.md).

| # | Decision |
| --- | --- |
| [0001](0001-one-app-profile-per-account.md) | One app profile per account |
| [0002](0002-copy-sessions-instead-of-linking.md) | Copy session records between account folders instead of linking them |
| [0003](0003-quit-with-sigterm-and-wait-for-updater.md) | Quit with a signal (SIGQUIT) and wait for the updater |
| [0004](0004-limit-detection-by-hook.md) | Detect limits with a Claude Code hook that only drops an event file |

New decisions get the next number. A decision that is reversed keeps its file and gains a
"Superseded by" line.
